// BrowserSyncBoostModels.swift

import Foundation

// MARK: - BrowserSyncBoostRecord

/// A site boost as sync carries it, name and styling included. Identity lives
/// beside it: after a delete, a new boost for the same host takes a fresh
/// identity, since the server keeps every deletion forever.
struct BrowserSyncBoostRecord: Codable, Equatable {
    static let hostLimit = Int(limits.host)
    static let codeLimit = Int(limits.code)
    static let selectorLimit = Int(limits.selector)
    static let selectorCountLimit = Int(limits.selectorCount)
    static let titleLimit = Int(limits.title)

    /// Limits in UTF-16 code units, as the server counts them. The sync protocol crate keeps them.
    private static let limits = coreSyncBoostLimits()

    var host: String
    var isEnabled: Bool
    var css: String
    var javaScript: String
    var zappedSelectors: [String]
    /// The name the user gave the boost; nil shows the default name.
    var title: String?
    /// What the editor's controls change; nil keeps the site's own look.
    var style: BrowserSyncBoostStyle?

    /// Whether the server accepts it. A boost over the limits stays on this Mac.
    var isSyncable: Bool {
        (1...Self.hostLimit).contains(host.utf16.count)
            && css.utf16.count <= Self.codeLimit
            && javaScript.utf16.count <= Self.codeLimit
            && zappedSelectors.count <= Self.selectorCountLimit
            && zappedSelectors.allSatisfy { (1...Self.selectorLimit).contains($0.utf16.count) }
            && title.map { (1...Self.titleLimit).contains($0.utf16.count) } ?? true
            && style?.isSyncable ?? true
    }
}

// MARK: - BrowserSyncBoostStyle

/// Colors, a font, a text case and a size. Sync bounds each number more
/// widely than the editor, so a later editor can widen its own ranges.
struct BrowserSyncBoostStyle: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case colors, fontFamily, textCase, textZoom
    }

    static let fontFamilyLimit = 256
    static let hueRange: ClosedRange<Double> = 0...360
    static let secondaryHueOffsetRange: ClosedRange<Double> = -360...360
    static let unitRange: ClosedRange<Double> = 0...1
    static let colorScaleRange: ClosedRange<Double> = 0...4
    static let textZoomRange: ClosedRange<Double> = 0.25...4

    var colors: BrowserBoostColors?
    var fontFamily: String?
    var textCase: BrowserBoostTextCase?
    var textZoom: Double?

    /// Nil when nothing differs from the site's own look.
    var nonEmpty: Self? {
        colors == nil && fontFamily == nil && textCase == nil && textZoom == nil ? nil : self
    }

    var isSyncable: Bool {
        fontFamily.map { (1...Self.fontFamilyLimit).contains($0.utf16.count) } ?? true
            && textZoom.map(Self.textZoomRange.contains) ?? true
            && colors.map(Self.areSyncable) ?? true
    }

    #if os(macOS)
    /// A boost's style with every number moved into the bounds sync accepts.
    /// The iPhone keeps synced boosts without showing them, so only the Mac makes one.
    init(_ boost: BrowserBoost) {
        self.colors = boost.colors.map(Self.bounded)
        self.fontFamily = boost.fontFamily
        self.textCase = boost.textCase
        self.textZoom = boost.textZoom.map { Self.bounded($0, to: Self.textZoomRange, default: 1) }
    }
    #endif

    init(
        colors: BrowserBoostColors? = nil,
        fontFamily: String? = nil,
        textCase: BrowserBoostTextCase? = nil,
        textZoom: Double? = nil,
    ) {
        self.colors = colors
        self.fontFamily = fontFamily
        self.textCase = textCase
        self.textZoom = textZoom
    }

    /// Reads each field on its own, so a field a later version shapes
    /// differently drops alone instead of failing the whole boost.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.colors = try? values.decodeIfPresent(BrowserBoostColors.self, forKey: .colors)
        self.fontFamily = try? values.decodeIfPresent(String.self, forKey: .fontFamily)
        self.textCase = (try? values.decodeIfPresent(String.self, forKey: .textCase))
            .flatMap(BrowserBoostTextCase.init(rawValue:))
        self.textZoom = try? values.decodeIfPresent(Double.self, forKey: .textZoom)
    }

    private static func areSyncable(_ colors: BrowserBoostColors) -> Bool {
        colorScaleRange.contains(colors.contrast) && colorScaleRange.contains(colors.brightness)
            && unitRange.contains(colors.originalSaturation)
            && colors.tint.map {
                hueRange.contains($0.hue) && unitRange.contains($0.saturation)
                    && secondaryHueOffsetRange.contains($0.secondaryHueOffset)
            } ?? true
    }

    private static func bounded(_ colors: BrowserBoostColors) -> BrowserBoostColors {
        BrowserBoostColors(
            tint: colors.tint.map {
                .init(
                    hue: bounded($0.hue, to: hueRange, default: 0),
                    saturation: bounded($0.saturation, to: unitRange, default: 0),
                    secondaryHueOffset: bounded(
                        $0.secondaryHueOffset, to: secondaryHueOffsetRange,
                        default: BrowserBoostColors.Tint.defaultSecondaryHueOffset,
                    ),
                )
            },
            invertsLightness: colors.invertsLightness,
            contrast: bounded(colors.contrast, to: colorScaleRange, default: 1),
            brightness: bounded(colors.brightness, to: colorScaleRange, default: 1),
            originalSaturation: bounded(colors.originalSaturation, to: unitRange, default: 0),
        )
    }

    private static func bounded(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

// MARK: - BrowserSyncBoostEntry

struct BrowserSyncBoostEntry: Equatable {
    let id: String
    let record: BrowserSyncBoostRecord
}

// MARK: - BrowserSyncBoostOperation

/// An upsert replaces the whole boost; the last committed write wins. A delete
/// is permanent.
enum BrowserSyncBoostOperation: Codable, Equatable {
    case upsert(id: String, record: BrowserSyncBoostRecord)
    case delete(id: String)

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, entityType, entityID, data
    }

    // MARK: Internal

    var entityID: String {
        switch self {
        case .delete(let id),
             .upsert(let id, _): id
        }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .entityType) == "boost" else {
            throw BrowserSyncBoostError.invalidOperation
        }
        let id = try values.decode(String.self, forKey: .entityID)
        switch try values.decode(String.self, forKey: .kind) {
        case "upsert": self = try .upsert(id: id, record: values.decode(BrowserSyncBoostRecord.self, forKey: .data))
        case "delete": self = .delete(id: id)
        default: throw BrowserSyncBoostError.invalidOperation
        }
        try validate()
    }

    func validate() throws {
        guard (1...200).contains(entityID.utf16.count) else { throw BrowserSyncBoostError.invalidOperation }
        if case .upsert(_, let record) = self, !record.isSyncable {
            throw BrowserSyncBoostError.invalidOperation
        }
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let id, let record):
            try values.encode("upsert", forKey: .kind)
            try values.encode("boost", forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(record, forKey: .data)
        case .delete(let id):
            try values.encode("delete", forKey: .kind)
            try values.encode("boost", forKey: .entityType)
            try values.encode(id, forKey: .entityID)
        }
    }
}

// MARK: - BrowserSyncBoostMutation

struct BrowserSyncBoostMutation: Codable, Equatable {
    let id: String
    let operations: [BrowserSyncBoostOperation]

    func validate() throws {
        guard UUID(uuidString: id) != nil else { throw BrowserSyncQueueError.invalidMutationIdentity }
        guard (1...1000).contains(operations.count) else { throw BrowserSyncBoostError.invalidOperation }
        for operation in operations {
            try operation.validate()
        }
    }
}

// MARK: - BrowserSyncBoostError

enum BrowserSyncBoostError: Error, Equatable {
    case invalidOperation
}

// MARK: - BrowserSyncBoostPushRequest

struct BrowserSyncBoostPushRequest: Encodable {
    let protocolVersion = 6
    let mutationID: String
    let deviceID: String
    let operations: [BrowserSyncBoostOperation]
}

// MARK: - BrowserSyncBoostOutcome

struct BrowserSyncBoostOutcome: Codable, Equatable {
    enum Status: String, Codable { case applied, deleted, rejected }

    let operationIndex: Int
    let status: Status
    let reason: String?
}

// MARK: - BrowserSyncBoostPushResponse

struct BrowserSyncBoostPushResponse: Codable, Equatable {
    let protocolVersion: Int
    let mutationID: String
    let cursor: Int
    let events: [BrowserSyncEvent]
    let outcomes: [BrowserSyncBoostOutcome]

    /// Checked at the transport and the coordinator: a receipt for another
    /// mutation, or one that carries other entities, must not consume a queue row.
    func validate(for mutation: BrowserSyncBoostMutation) throws {
        try mutation.validate()
        guard protocolVersion == 6, mutationID == mutation.id, cursor >= 0,
              outcomes.count == mutation.operations.count,
              Set(outcomes.map(\.operationIndex)) == Set(mutation.operations.indices)
        else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        let requestedIDs = Set(mutation.operations.map(\.entityID))
        for event in events {
            guard event.entityType == "boost", requestedIDs.contains(event.entityID),
                  event.serverSeq > 0, event.serverSeq <= cursor
            else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        }
    }
}

// MARK: - BrowserSyncEventBoostData

struct BrowserSyncEventBoostData: Codable, Equatable {
    let id: String
    let host: String?
    let isEnabled: Bool?
    let css: String?
    let javaScript: String?
    let zappedSelectors: [String]?
    let title: String?
    let style: BrowserSyncBoostStyle?

    var record: BrowserSyncBoostRecord? {
        guard let host, let isEnabled, let css, let javaScript, let zappedSelectors else { return nil }
        return BrowserSyncBoostRecord(
            host: host, isEnabled: isEnabled, css: css, javaScript: javaScript, zappedSelectors: zappedSelectors,
            title: title, style: style?.nonEmpty,
        )
    }

    init(
        id: String,
        host: String?,
        isEnabled: Bool?,
        css: String?,
        javaScript: String?,
        zappedSelectors: [String]?,
        title: String? = nil,
        style: BrowserSyncBoostStyle? = nil,
    ) {
        self.id = id
        self.host = host
        self.isEnabled = isEnabled
        self.css = css
        self.javaScript = javaScript
        self.zappedSelectors = zappedSelectors
        self.title = title
        self.style = style
    }

    init(id: String, record: BrowserSyncBoostRecord) {
        self.init(
            id: id, host: record.host, isEnabled: record.isEnabled, css: record.css, javaScript: record.javaScript,
            zappedSelectors: record.zappedSelectors, title: record.title, style: record.style,
        )
    }
}

// MARK: - BrowserSyncBoostBaseline

/// The server's boosts as this device last read them. Deletions stay forever:
/// no later event or queued write brings a deleted identity back.
struct BrowserSyncBoostBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let serverSeq: Int
        /// Nil once deleted.
        let record: BrowserSyncBoostRecord?
    }

    var entries = [String: Entry]()

    /// Keeps only the deletions, for a rebuild from cursor zero.
    var tombstones: Self {
        Self(entries: entries.filter { $0.value.record == nil })
    }

    mutating func apply(_ events: [BrowserSyncEvent]) throws {
        for event in events.sorted(by: { $0.serverSeq < $1.serverSeq }) where event.entityType == "boost" {
            guard event.serverSeq >= 0 else { throw BrowserSyncOutboxError.invalidEvent }
            let current = entries[event.entityID]
            guard event.serverSeq > (current?.serverSeq ?? -1) else { continue }
            switch (event.op, event.data) {
            case ("delete", .deleted):
                entries[event.entityID] = Entry(serverSeq: event.serverSeq, record: nil)
            case ("upsert", .boost(let data)):
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

// MARK: - BrowserSyncBoostState

/// The server's boosts with this device's queued boost writes on top: what
/// the device shows once those writes are accepted.
struct BrowserSyncBoostState: Equatable {
    struct Live: Equatable {
        /// The server sequence, or above every sequence for a queued write, so
        /// the newest write of a host wins.
        let rank: Int
        let record: BrowserSyncBoostRecord
    }

    var live = [String: Live]()
    var deleted = Set<String>()

    /// One boost per host, the most recently written, ordered by host. Two
    /// devices can each create a boost for one host before they hear of the other.
    var winners: [BrowserSyncBoostEntry] {
        var best = [String: (id: String, live: Live)]()
        for (id, live) in live {
            if let current = best[live.record.host],
               current.live.rank > live.rank || (current.live.rank == live.rank && current.id > id)
            {
                continue
            }
            best[live.record.host] = (id, live)
        }
        return best.values
            .sorted { $0.live.record.host < $1.live.record.host }
            .map { BrowserSyncBoostEntry(id: $0.id, record: $0.live.record) }
    }

    init(baseline: BrowserSyncBoostBaseline, pending: [BrowserSyncQueuedMutation]) {
        for (id, entry) in baseline.entries {
            if let record = entry.record {
                live[id] = Live(rank: entry.serverSeq, record: record)
            } else {
                deleted.insert(id)
            }
        }
        var rank = Int(Int32.max)
        for case .boosts(let mutation) in pending {
            for operation in mutation.operations {
                rank += 1
                switch operation {
                case .upsert(let id, let record):
                    guard !deleted.contains(id) else { continue }
                    live[id] = Live(rank: rank, record: record)
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

    func liveIDs(forHost host: String) -> [String] {
        live.filter { $0.value.record.host == host }.map(\.key).sorted()
    }

    /// Writes that bring local boosts the server has not seen into sync. A
    /// local boost for a host the server already has replaces that boost's
    /// content: enabling sync is the latest write.
    func adoptionOperations(for local: [BrowserSyncBoostEntry]) -> [BrowserSyncBoostOperation] {
        var operations = [BrowserSyncBoostOperation]()
        var adoptedHosts = Set<String>()
        let winners = Dictionary(winners.map { ($0.record.host, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in local where !knows(entry.id) && entry.record.isSyncable {
            guard adoptedHosts.insert(entry.record.host).inserted else { continue }
            if let winner = winners[entry.record.host] {
                if winner.record != entry.record {
                    operations.append(.upsert(id: winner.id, record: entry.record))
                }
            } else {
                operations.append(.upsert(id: entry.id, record: entry.record))
            }
        }
        return operations
    }
}

// MARK: - BrowserSyncBoostApplying

/// Shows synced boosts. The app-wide boosts follow one profile's account.
@MainActor protocol BrowserSyncBoostApplying: AnyObject {
    /// The boosts on this device, for the first upload when boost sync starts.
    func localSyncBoosts() -> [BrowserSyncBoostEntry]
    /// The synced boosts changed: show the new state.
    func syncBoostsDidChange()
}
