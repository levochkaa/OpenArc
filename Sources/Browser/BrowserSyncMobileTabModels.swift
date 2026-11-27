// BrowserSyncMobileTabModels.swift

import Foundation

// MARK: - BrowserSyncMobileTabRecord

/// A tab of the account's phones and tablets. Mobile tabs are their own list,
/// apart from Spaces: every mobile device shows the same tabs, and computers
/// only read them. Identity lives beside the record, and a deleted identity
/// never comes back.
struct BrowserSyncMobileTabRecord: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case urlString, title, createdAt, lastActivityAt
    }

    /// Limits in UTF-16 code units, as the server counts them.
    static let urlLimit = 8192
    static let titleLimit = 1024

    var urlString: String
    /// The page's title; nil until the page reports one.
    var title: String?
    var createdAt: Date
    /// The last time a device showed the tab. The server keeps the latest it hears of.
    var lastActivityAt: Date?

    /// A blank tab stays on its device until it opens a page.
    var isSyncable: Bool {
        (1...Self.urlLimit).contains(urlString.utf16.count) && urlString != "about:blank"
            && title.map { (1...Self.titleLimit).contains($0.utf16.count) } ?? true
            && createdAt.timeIntervalSince1970.isFinite
            && lastActivityAt.map { $0.timeIntervalSince1970.isFinite } ?? true
    }

    init(urlString: String, title: String? = nil, createdAt: Date, lastActivityAt: Date? = nil) {
        self.urlString = urlString
        self.title = title
        self.createdAt = Self.wholeSecond(createdAt)
        self.lastActivityAt = lastActivityAt.map(Self.wholeSecond)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.urlString = try values.decode(String.self, forKey: .urlString)
        self.title = try values.decodeIfPresent(String.self, forKey: .title)
        guard let created = try Self.date(values.decode(String.self, forKey: .createdAt)) else {
            throw BrowserSyncMobileTabError.invalidOperation
        }
        self.createdAt = created
        self.lastActivityAt = try values.decodeIfPresent(String.self, forKey: .lastActivityAt).flatMap(Self.date)
    }

    /// Dates go out in whole seconds, UTC.
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: wholeSecond(date))
    }

    /// Reads the server's six fractional digits as well as whole seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        // ISO8601DateFormatter reads at most three fractional digits.
        guard let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." })
        else { return nil }
        let digits = text[text.index(after: dot)..<end]
        let trimmed = String(text[..<dot]) + "." + digits.prefix(3) + String(text[end...])
        return fractional.date(from: trimmed)
    }

    static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let left?, let right?): max(left, right)
        case (let left?, nil): left
        case (nil, let right): right
        }
    }

    private static func wholeSecond(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds.rounded(.down)) : date
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(urlString, forKey: .urlString)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encode(Self.string(createdAt), forKey: .createdAt)
        try values.encodeIfPresent(lastActivityAt.map(Self.string), forKey: .lastActivityAt)
    }
}

// MARK: - BrowserSyncMobileTabEntry

struct BrowserSyncMobileTabEntry: Codable, Equatable {
    let id: String
    var record: BrowserSyncMobileTabRecord
}

// MARK: - BrowserSyncMobileTabOperation

/// An upsert replaces the whole tab, except that activity only moves forward.
/// A delete is permanent.
enum BrowserSyncMobileTabOperation: Codable, Equatable {
    case upsert(id: String, record: BrowserSyncMobileTabRecord)
    case delete(id: String)

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, entityType, entityID, data
    }

    // MARK: Internal

    static let entityType = "mobileTab"

    var entityID: String {
        switch self {
        case .delete(let id),
             .upsert(let id, _): id
        }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .entityType) == Self.entityType else {
            throw BrowserSyncMobileTabError.invalidOperation
        }
        let id = try values.decode(String.self, forKey: .entityID)
        switch try values.decode(String.self, forKey: .kind) {
        case "upsert": self = try .upsert(
                id: id, record: values.decode(BrowserSyncMobileTabRecord.self, forKey: .data),
            )
        case "delete": self = .delete(id: id)
        default: throw BrowserSyncMobileTabError.invalidOperation
        }
        try validate()
    }

    func validate() throws {
        guard (1...200).contains(entityID.utf16.count) else { throw BrowserSyncMobileTabError.invalidOperation }
        if case .upsert(_, let record) = self, !record.isSyncable {
            throw BrowserSyncMobileTabError.invalidOperation
        }
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let id, let record):
            try values.encode("upsert", forKey: .kind)
            try values.encode(Self.entityType, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(record, forKey: .data)
        case .delete(let id):
            try values.encode("delete", forKey: .kind)
            try values.encode(Self.entityType, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
        }
    }
}

// MARK: - BrowserSyncMobileTabMutation

struct BrowserSyncMobileTabMutation: Codable, Equatable {
    let id: String
    let operations: [BrowserSyncMobileTabOperation]

    func validate() throws {
        guard UUID(uuidString: id) != nil else { throw BrowserSyncQueueError.invalidMutationIdentity }
        guard (1...1000).contains(operations.count) else { throw BrowserSyncMobileTabError.invalidOperation }
        for operation in operations {
            try operation.validate()
        }
    }
}

// MARK: - BrowserSyncMobileTabError

enum BrowserSyncMobileTabError: Error, Equatable {
    case invalidOperation
}

// MARK: - BrowserSyncMobileTabPushRequest

struct BrowserSyncMobileTabPushRequest: Encodable {
    let protocolVersion = 7
    let mutationID: String
    let deviceID: String
    let operations: [BrowserSyncMobileTabOperation]
}

// MARK: - BrowserSyncMobileTabPushResponse

struct BrowserSyncMobileTabPushResponse: Codable, Equatable {
    let protocolVersion: Int
    let mutationID: String
    let cursor: Int
    let events: [BrowserSyncEvent]
    let outcomes: [BrowserSyncBoostOutcome]

    /// A receipt for another mutation, or one that carries other entities,
    /// must not consume a queue row.
    func validate(for mutation: BrowserSyncMobileTabMutation) throws {
        try mutation.validate()
        guard protocolVersion == 7, mutationID == mutation.id, cursor >= 0,
              outcomes.count == mutation.operations.count,
              Set(outcomes.map(\.operationIndex)) == Set(mutation.operations.indices)
        else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        let requestedIDs = Set(mutation.operations.map(\.entityID))
        for event in events {
            guard event.entityType == BrowserSyncMobileTabOperation.entityType,
                  requestedIDs.contains(event.entityID), event.serverSeq > 0, event.serverSeq <= cursor
            else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        }
    }
}

// MARK: - BrowserSyncEventMobileTabData

struct BrowserSyncEventMobileTabData: Codable, Equatable {
    let id: String
    let urlString: String?
    let title: String?
    let createdAt: String?
    let lastActivityAt: String?

    var record: BrowserSyncMobileTabRecord? {
        guard let urlString, let createdAt, let created = BrowserSyncMobileTabRecord.date(createdAt) else {
            return nil
        }
        return BrowserSyncMobileTabRecord(
            urlString: urlString, title: title, createdAt: created,
            lastActivityAt: lastActivityAt.flatMap(BrowserSyncMobileTabRecord.date),
        )
    }

    init(id: String, urlString: String?, title: String?, createdAt: String?, lastActivityAt: String?) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    init(id: String, record: BrowserSyncMobileTabRecord) {
        self.init(
            id: id, urlString: record.urlString, title: record.title,
            createdAt: BrowserSyncMobileTabRecord.string(record.createdAt),
            lastActivityAt: record.lastActivityAt.map(BrowserSyncMobileTabRecord.string),
        )
    }
}

// MARK: - BrowserSyncMobileTabBaseline

/// The server's mobile tabs as this device last read them. Deletions stay forever.
struct BrowserSyncMobileTabBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let serverSeq: Int
        /// Nil once deleted.
        let record: BrowserSyncMobileTabRecord?
    }

    var entries = [String: Entry]()

    /// Keeps only the deletions, for a rebuild from cursor zero.
    var tombstones: Self {
        Self(entries: entries.filter { $0.value.record == nil })
    }

    mutating func apply(_ events: [BrowserSyncEvent]) throws {
        for event in events.sorted(by: { $0.serverSeq < $1.serverSeq })
            where event.entityType == BrowserSyncMobileTabOperation.entityType
        {
            guard event.serverSeq >= 0 else { throw BrowserSyncOutboxError.invalidEvent }
            let current = entries[event.entityID]
            guard event.serverSeq > (current?.serverSeq ?? -1) else { continue }
            switch (event.op, event.data) {
            case ("delete", .deleted):
                entries[event.entityID] = Entry(serverSeq: event.serverSeq, record: nil)
            case ("upsert", .mobileTab(let data)):
                guard let record = data.record else { throw BrowserSyncOutboxError.invalidEvent }
                // A tombstone is permanent even against a later upsert event.
                guard current == nil || current?.record != nil else { continue }
                entries[event.entityID] = Entry(serverSeq: event.serverSeq, record: record)
            default:
                throw BrowserSyncOutboxError.invalidEvent
            }
        }
    }
}

// MARK: - BrowserSyncMobileTabState

/// The server's mobile tabs with this device's queued writes on top: what the
/// device shows once those writes are accepted.
struct BrowserSyncMobileTabState: Equatable {
    var live = [String: BrowserSyncMobileTabRecord]()
    var deleted = Set<String>()

    /// Live tabs, the oldest first.
    var entries: [BrowserSyncMobileTabEntry] {
        live.map { BrowserSyncMobileTabEntry(id: $0.key, record: $0.value) }
            .sorted { $0.record.createdAt == $1.record.createdAt ? $0.id < $1.id : $0.record.createdAt < $1.record.createdAt }
    }

    init(baseline: BrowserSyncMobileTabBaseline, pending: [BrowserSyncQueuedMutation]) {
        for (id, entry) in baseline.entries {
            if let record = entry.record {
                live[id] = record
            } else {
                deleted.insert(id)
            }
        }
        for case .mobileTabs(let mutation) in pending {
            for operation in mutation.operations {
                switch operation {
                case .upsert(let id, var record):
                    guard !deleted.contains(id) else { continue }
                    record.lastActivityAt = BrowserSyncMobileTabRecord.latest(
                        record.lastActivityAt, live[id]?.lastActivityAt,
                    )
                    live[id] = record
                case .delete(let id):
                    live[id] = nil
                    deleted.insert(id)
                }
            }
        }
    }

    func knows(_ id: String) -> Bool {
        live[id] != nil || deleted.contains(id)
    }

    /// Uploads local tabs the server has not seen, when mobile tab sync starts.
    func adoptionOperations(for local: [BrowserSyncMobileTabEntry]) -> [BrowserSyncMobileTabOperation] {
        local.filter { !knows($0.id) && $0.record.isSyncable }.map { .upsert(id: $0.id, record: $0.record) }
    }
}

// MARK: - BrowserSyncMobileTabApplying

/// Shows synced mobile tabs: a phone or tablet keeps them as its tabs, a
/// computer lists them.
@MainActor protocol BrowserSyncMobileTabApplying: AnyObject {
    /// This device's mobile tabs, for the first upload when mobile tab sync starts.
    func localSyncMobileTabs() -> [BrowserSyncMobileTabEntry]
    /// The synced mobile tabs changed.
    func syncMobileTabsDidChange()
}
