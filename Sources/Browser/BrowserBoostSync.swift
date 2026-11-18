// BrowserBoostSync.swift

import Combine
import Foundation
import OSLog

// MARK: - BrowserBoostSyncStoring

/// The profile store that queues boost writes and keeps the synced boosts.
protocol BrowserBoostSyncStoring: AnyObject {
    func loadSyncBoostState() throws -> BrowserSyncBoostState?
    @discardableResult func enqueueSyncBoosts(_ operations: [BrowserSyncBoostOperation]) throws -> Bool
}

// MARK: - BrowserSQLiteSessionStore + BrowserBoostSyncStoring

extension BrowserSQLiteSessionStore: BrowserBoostSyncStoring {}

// MARK: - BrowserBoostSyncMerge

/// The rules between this Mac's boosts and the synced ones.
enum BrowserBoostSyncMerge {
    /// Writes for local edits. A changed boost replaces its synced record and
    /// retires the host's other synced boosts; a removed boost is deleted with
    /// the host's others, unless another local boost now holds the host. A boost
    /// deleted elsewhere stays deleted: the edit does not bring it back.
    static func operations(
        changedIDs: Set<String>,
        removed: [String: String],
        local: [BrowserBoost],
        state: BrowserSyncBoostState,
    ) -> [BrowserSyncBoostOperation] {
        var operations = [BrowserSyncBoostOperation]()
        var deleting = Set<String>()
        var written = Set<String>()
        for boost in local where changedIDs.contains(boost.syncID) {
            let record = boost.syncRecord
            guard record.isSyncable, !state.deleted.contains(boost.syncID) else { continue }
            written.insert(boost.syncID)
            if state.live[boost.syncID]?.record != record {
                operations.append(.upsert(id: boost.syncID, record: record))
            }
            for other in state.liveIDs(forHost: boost.host) where other != boost.syncID {
                if deleting.insert(other).inserted {
                    operations.append(.delete(id: other))
                }
            }
        }
        let localHosts = Set(local.map(\.host))
        for (id, host) in removed.sorted(by: { $0.key < $1.key }) {
            if state.live[id] != nil, !written.contains(id), deleting.insert(id).inserted {
                operations.append(.delete(id: id))
            }
            guard !localHosts.contains(host) else { continue }
            for other in state.liveIDs(forHost: host) where deleting.insert(other).inserted {
                operations.append(.delete(id: other))
            }
        }
        return operations
    }

    /// The boosts to show: each host's synced boost in this Mac's order, then
    /// hosts that are new here. A local boost sync does not know yet stays.
    static func merged(local: [BrowserBoost], state: BrowserSyncBoostState) -> [BrowserBoost] {
        let winners = state.winners
        let winnerByHost = Dictionary(winners.map { ($0.record.host, $0) }, uniquingKeysWith: { first, _ in first })
        var result = [BrowserBoost]()
        var shownHosts = Set<String>()
        for boost in local where !shownHosts.contains(boost.host) {
            if let winner = winnerByHost[boost.host] {
                result.append(BrowserBoost(winner))
                shownHosts.insert(boost.host)
            } else if !state.knows(boost.syncID) {
                result.append(boost)
                shownHosts.insert(boost.host)
            }
        }
        for winner in winners where shownHosts.insert(winner.record.host).inserted {
            result.append(BrowserBoost(winner))
        }
        return result
    }
}

// MARK: - BrowserBoostSyncBridge

/// Keeps the app's boosts and one profile's synced boosts in step. Removals
/// queue at once; edits queue after a pause, since the boost editor saves CSS
/// while the user types. Pending edits queue before remote boosts are shown.
@MainActor final class BrowserBoostSyncBridge: BrowserSyncBoostApplying {
    // MARK: Private

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.OpenArc", category: "BoostSync",
    )

    private let store: any BrowserBoostSyncStoring
    private let preferences: BrowserUserPreferencesStore
    private let debounce: Duration
    private let wake: @MainActor () -> Void
    /// The boosts as the preferences hold them, including a change being set.
    private var shown: [BrowserBoost]
    private var changedIDs = Set<String>()
    /// Removed boost identities and their hosts.
    private var removed = [String: String]()
    private var flushTask: Task<Void, Never>?
    private var isApplying = false
    private var cancellable: AnyCancellable?

    // MARK: Internal

    init(
        store: any BrowserBoostSyncStoring,
        preferences: BrowserUserPreferencesStore,
        debounce: Duration = .seconds(2),
        wake: @escaping @MainActor () -> Void = {},
    ) {
        self.store = store
        self.preferences = preferences
        self.debounce = debounce
        self.wake = wake
        self.shown = preferences.boosts
        // `@Published` sends before it stores; `shown` follows what it sends.
        self.cancellable = preferences.$boosts.dropFirst().sink { [weak self] boosts in
            MainActor.assumeIsolated { self?.boostsWillChange(to: boosts) }
        }
        reconcile()
    }

    func localSyncBoosts() -> [BrowserSyncBoostEntry] {
        shown.map { BrowserSyncBoostEntry(id: $0.syncID, record: $0.syncRecord) }
            .filter(\.record.isSyncable)
    }

    func syncBoostsDidChange() {
        flush()
        applySyncedBoosts()
    }

    /// Queues edits still waiting for their pause, for example before quitting.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !changedIDs.isEmpty || !removed.isEmpty else { return }
        let changed = changedIDs
        let removed = removed
        changedIDs = []
        self.removed = [:]
        do {
            // Before boost sync starts its first upload takes every local boost.
            guard let state = try store.loadSyncBoostState() else { return }
            let operations = BrowserBoostSyncMerge.operations(
                changedIDs: changed, removed: removed, local: shown, state: state,
            )
            if !operations.isEmpty, try store.enqueueSyncBoosts(operations) {
                wake()
            }
        } catch {
            Self.logger.error("Boost sync write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// At launch: boosts made while this profile could not queue them go up,
    /// and boosts changed elsewhere come down.
    private func reconcile() {
        do {
            guard let state = try store.loadSyncBoostState() else { return }
            let unknown = Set(shown.map(\.syncID).filter { !state.knows($0) })
            let operations = BrowserBoostSyncMerge.operations(
                changedIDs: unknown, removed: [:], local: shown, state: state,
            )
            if !operations.isEmpty, try store.enqueueSyncBoosts(operations) {
                wake()
            }
        } catch {
            Self.logger.error("Boost sync write failed: \(error.localizedDescription, privacy: .public)")
        }
        applySyncedBoosts()
    }

    private func applySyncedBoosts() {
        do {
            guard let state = try store.loadSyncBoostState() else { return }
            let merged = BrowserBoostSyncMerge.merged(local: shown, state: state)
            guard merged != shown else { return }
            isApplying = true
            preferences.boosts = merged
            isApplying = false
        } catch {
            Self.logger.error("Boost sync read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func boostsWillChange(to boosts: [BrowserBoost]) {
        defer { shown = boosts }
        guard !isApplying else { return }
        let previous = Dictionary(shown.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(boosts.map(\.syncID))
        for boost in shown where !currentIDs.contains(boost.syncID) {
            removed[boost.syncID] = boost.host
            changedIDs.remove(boost.syncID)
        }
        for boost in boosts where previous[boost.syncID] != boost {
            changedIDs.insert(boost.syncID)
            removed[boost.syncID] = nil
        }
        if !removed.isEmpty {
            // Queue a delete at once: a quit before the pause must not bring the boost back.
            DispatchQueue.main.async { [weak self] in self?.flush() }
        } else if !changedIDs.isEmpty {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let debounce = debounce
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            self?.flush()
        }
    }
}
