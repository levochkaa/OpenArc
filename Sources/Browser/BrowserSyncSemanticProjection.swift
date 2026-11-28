// BrowserSyncSemanticProjection.swift

import Foundation

/// Protocol version 3 operations, computed by the Rust core (`sync::semantic`). Direct moves retain the
/// identities the user moved. Snapshot-only callers infer a minimal move set from relative order.
enum BrowserSyncSemanticProjection {
    static func operations(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        syncMove: BrowserSyncMoveIntent? = nil,
    ) -> [BrowserSyncSemanticOperation] {
        coreSyncSemanticOperations(
            previous: previous?.core, snapshot: snapshot.core,
            moveTabIds: syncMove.map { previous == snapshot ? [] : $0.tabIDs },
            defaultSpaceTitle: BrowserSyncOutboxProjection.defaultSpaceTitle,
        )
        .map(BrowserSyncSemanticOperation.init)
    }

    static func apply(
        _ operations: [BrowserSyncSemanticOperation],
        to values: inout [String: BrowserSyncChange],
        deleted: inout Set<String>,
    ) {
        let state = coreSyncSemanticApply(
            operations: operations.map(\.core),
            state: BrowserSyncOutboxReplayState(values: values, deleted: deleted).core,
        )
        values = state.values.mapValues(BrowserSyncChange.init)
        deleted = Set(state.deleted)
    }
}
