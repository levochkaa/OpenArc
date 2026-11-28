// BrowserSyncOutbox.swift

import Foundation

// MARK: - BrowserSyncOutboxError

enum BrowserSyncOutboxError: Error, Equatable {
    case invalidLimit
    case invalidEvent
}

// MARK: - BrowserSyncActivityDates

/// Pending activity never decreases a known canonical value. Keep this policy
/// in projections: canonical events and immutable queued requests retain their bytes.
/// The Rust core reads the dates as `Date.ISO8601FormatStyle` of macOS 26 does (`sync::dates`).
struct BrowserSyncActivityDates {
    func latest(_ current: String?, _ incoming: String?) -> String? {
        coreSyncLatestActivity(current: current, incoming: incoming)
    }

    func projectedTimestamp(_ incoming: String?, local: TimeInterval?) -> TimeInterval? {
        coreSyncProjectedActivity(incoming: incoming, local: local)
    }
}

// MARK: - BrowserSyncOutboxBaseline

struct BrowserSyncOutboxBaseline: Codable {
    struct Entity: Codable {
        let serverSeq: Int
        let change: BrowserSyncChange
    }

    var entities = [String: Entity]()
    var deletedKeys = Set<String>()

    mutating func recordLocalDeletes(_ changes: [BrowserSyncChange]) {
        for change in changes where change.op == .delete {
            deletedKeys.insert(BrowserSyncOutboxProjection.key(change))
        }
    }

    /// Applies server events in sequence order: replayed older events are skipped, server deletes are
    /// permanent (`sync::outbox` in the Rust core). Only the entities the events name cross into the core.
    mutating func apply(_ events: [BrowserSyncEvent]) throws {
        let named = Set(events.map { "\($0.entityType):\($0.entityID)" })
        let update: CoreSyncBaselineUpdate
        do {
            update = try coreSyncBaselineUpdate(
                entities: entities.filter { named.contains($0.key) }.mapValues(\.core),
                events: events.map(\.core),
            )
        } catch is CoreSyncError {
            throw BrowserSyncOutboxError.invalidEvent
        }
        for (key, entity) in update.entities {
            entities[key] = Entity(entity)
        }
        deletedKeys.formUnion(update.deletedKeys)
    }
}

// MARK: - BrowserSyncQueuedRowIdentity

/// One stored queue row as bytes. Rows that decode to equal values can still
/// differ in bytes, for example in Unicode normalization.
struct BrowserSyncQueuedRowIdentity: Equatable {
    let protocolVersion: Int
    let payload: Data
}

// MARK: - BrowserSyncOutboxReplayState

/// Queue replay state: canonical values with the replayed rows applied, and the
/// keys hidden so far.
struct BrowserSyncOutboxReplayState {
    var values: [String: BrowserSyncChange]
    var deleted: Set<String>

    /// Equal down to string bytes and rank bits, so replaying the same rows
    /// from either state yields the same bytes. `==` would accept strings that
    /// differ only in Unicode normalization.
    func isIdentical(to other: Self) -> Bool {
        coreSyncReplayStatesIdentical(left: core, right: other.core)
    }
}

// MARK: - BrowserSyncOutboxReplayMemo

/// The last queue replay, kept in the Rust core so an ACK need not replay the rest of the queue. It holds
/// only facts about the pure replay; a rolled-back transaction, another account or another writer can make
/// it useless, never wrong: reuse also requires a byte-identical start.
final class BrowserSyncOutboxReplayMemo {
    let core = CoreSyncReplayMemo()

    /// How many replays this memo skipped.
    var reuses: Int { Int(core.reuses()) }
}

// MARK: - BrowserSyncOutboxProjection

/// The outbox projection, computed by the Rust core (`sync::outbox`): canonical entities of a session, and
/// the replay of queued rows over the acknowledged baseline into the session the app shows.
enum BrowserSyncOutboxProjection {
    /// The title of the Space that tabs without one belong to.
    static var defaultSpaceTitle: String { BrowserStrings.defaultSpaceTitle(index: 1) }

    static func key(type: BrowserSyncChange.EntityType, id: String) -> String { "\(type.rawValue):\(id)" }
    static func key(_ change: BrowserSyncChange) -> String { key(type: change.entityType, id: change.entityID) }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
    ) -> [BrowserSyncChange] {
        coreSyncChanges(previous: previous?.core, snapshot: snapshot.core, defaultSpaceTitle: defaultSpaceTitle)
            .map(BrowserSyncChange.init)
    }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation],
    ) -> [BrowserSyncChange] {
        changes(
            from: previous,
            to: snapshot,
            baseline: baseline,
            pending: pending.map(BrowserSyncQueuedMutation.legacy),
        )
    }

    /// v2 has one rank list for spaces and one global list for tabs. Ranks follow the
    /// canonical state until an insertion or reorder renumbers a list, so metadata edits
    /// never reorder; concurrent reorders keep the server's last-writer behavior (S07).
    @_disfavoredOverload static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation],
    ) -> [BrowserSyncChange] {
        coreSyncRebasedChanges(
            previous: previous?.core, snapshot: snapshot.core, baseline: baseline.core,
            pending: pending.map(\.core), defaultSpaceTitle: defaultSpaceTitle,
        )
        .map(BrowserSyncChange.init)
    }

    static func removingDeletedEntities(
        from snapshot: BrowserTabSessionSnapshot, baseline: BrowserSyncOutboxBaseline,
    ) -> BrowserTabSessionSnapshot {
        let removed = coreSyncRemovedEntities(snapshot: snapshot.core, deletedKeys: Array(baseline.deletedKeys))
        func keeping<Element>(_ elements: [Element], _ positions: [UInt32]) -> [Element] {
            let positions = Set(positions.map(Int.init))
            return elements.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
        }
        // Local split state follows the local writer; the store prunes
        // members that this filter removed.
        return BrowserTabSessionSnapshot(
            spaces: snapshot.spaces.map { keeping($0, removed.spaces) },
            pinnedTabFolders: snapshot.pinnedTabFolders.map { keeping($0, removed.folders) },
            tabs: keeping(snapshot.tabs, removed.tabs),
            splitGroups: snapshot.splitGroups,
        )
    }

    static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation],
        local: BrowserTabSessionSnapshot?,
    ) -> BrowserTabSessionSnapshot {
        snapshot(baseline: baseline, pending: pending.map(BrowserSyncQueuedMutation.legacy), local: local)
    }

    @_disfavoredOverload static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation],
        local: BrowserTabSessionSnapshot?,
        folderSyncEnabled: Bool = false,
        reusing reuse: (rows: [BrowserSyncQueuedRowIdentity], memo: BrowserSyncOutboxReplayMemo)? = nil,
    ) -> BrowserTabSessionSnapshot {
        if let reuse {
            precondition(reuse.rows.count == pending.count)
        }
        let projected = coreSyncProjectedSnapshot(
            baseline: baseline.core, pending: pending.map(\.core), local: local?.core,
            folderSyncEnabled: folderSyncEnabled, rows: reuse?.rows.map(\.core), memo: reuse?.memo.core,
        )
        // The core answers nothing when the projection is the local session to the byte.
        guard let projected else {
            return BrowserTabSessionSnapshot(
                spaces: local?.spaces, pinnedTabFolders: local?.pinnedTabFolders, tabs: local?.tabs ?? [],
            )
        }
        return .init(projected)
    }

    static func effectiveChanges(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
    ) -> [String: BrowserSyncChange] {
        coreSyncEffectiveChanges(baseline: baseline.core, pending: pending.map(\.core))
            .mapValues(BrowserSyncChange.init)
    }

    /// The same result as `effectiveChanges(baseline:pending:)`. When the start
    /// state equals, byte for byte, the state `memo` reached after the first
    /// row of a queue whose remaining rows are `rows`, the replay of those rows
    /// would repeat the remembered one, so its end state is reused. The start
    /// state already holds the tombstone rule for exactly those rows, so the
    /// comparison covers deletes that are still queued.
    static func effectiveChanges(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
        rows: [BrowserSyncQueuedRowIdentity], memo: BrowserSyncOutboxReplayMemo,
    ) -> [String: BrowserSyncChange] {
        precondition(rows.count == pending.count)
        return coreSyncEffectiveChangesReusing(
            baseline: baseline.core, pending: pending.map(\.core), rows: rows.map(\.core), memo: memo.core,
        )
        .mapValues(BrowserSyncChange.init)
    }

    /// Local tombstones are recorded before debounce, including deletes later in
    /// this FIFO. Replay their preceding creates/move-outs first. Authoritative
    /// server tombstones remain effective from the start.
    static func replayStart(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
    ) -> BrowserSyncOutboxReplayState {
        .init(coreSyncReplayStart(baseline: baseline.core, pending: pending.map(\.core)))
    }

    /// Applies one queued row. The result depends only on `state` and the row.
    static func replay(_ mutation: BrowserSyncQueuedMutation, into state: inout BrowserSyncOutboxReplayState) {
        state = .init(coreSyncReplay(mutation: mutation.core, state: state.core))
    }

    static func replayResult(
        _ state: BrowserSyncOutboxReplayState, baseline: BrowserSyncOutboxBaseline,
    ) -> [String: BrowserSyncChange] {
        coreSyncReplayResult(state: state.core, baseline: baseline.core).mapValues(BrowserSyncChange.init)
    }

    static func replacingRank(of change: BrowserSyncChange, with rank: Double?) -> BrowserSyncChange {
        .init(coreSyncReplacingRank(change: change.core, rank: rank))
    }

    static func canonicalChanges(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
        coreSyncCanonicalChanges(snapshot: snapshot.core, defaultSpaceTitle: defaultSpaceTitle)
            .map(BrowserSyncChange.init)
    }
}
