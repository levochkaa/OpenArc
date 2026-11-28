// BrowserSyncFolderProjection.swift

import Foundation

/// Protocol version 4 projection with typed sibling lists and current canonical subtrees, computed by the
/// Rust core (`sync::folders`). A supplied move intent identifies the acted-on roots; snapshot-only callers
/// retain a deterministic minimal-order fallback.
enum BrowserSyncFolderProjection {
    /// Uses the same validation as reduction, including valid semantic no-ops.
    static func canMove(
        items: [BrowserSyncEntityReference], destination: BrowserSyncFolderDestination,
        values: [String: BrowserSyncChange], deleted: Set<String> = [],
    ) -> Bool {
        coreSyncFolderCanMove(
            items: items.map(\.core), destination: destination.core, values: values.mapValues(\.core),
            deleted: Array(deleted),
        )
    }

    static func canonicalChanges(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
        coreSyncFolderCanonicalChanges(
            snapshot: snapshot.core, defaultSpaceTitle: BrowserSyncOutboxProjection.defaultSpaceTitle,
        )
        .map(BrowserSyncChange.init)
    }

    static func operations(
        from previous: BrowserTabSessionSnapshot?, to snapshot: BrowserTabSessionSnapshot,
        moveIntent: BrowserSyncMoveIntent? = nil,
    ) -> [BrowserSyncFolderOperation] {
        coreSyncFolderOperations(
            previous: previous?.core, snapshot: snapshot.core,
            moveItems: moveIntent.map { previous == snapshot ? [] : $0.items.map(\.core) },
            defaultSpaceTitle: BrowserSyncOutboxProjection.defaultSpaceTitle,
        )
        .map(BrowserSyncFolderOperation.init)
    }

    static func apply(
        _ operations: [BrowserSyncFolderOperation], to values: inout [String: BrowserSyncChange],
        deleted: inout Set<String>,
    ) {
        let state = coreSyncFolderApply(
            operations: operations.map(\.core),
            state: BrowserSyncOutboxReplayState(values: values, deleted: deleted).core,
        )
        values = state.values.mapValues(BrowserSyncChange.init)
        deleted = Set(state.deleted)
    }

    static func snapshot(
        values: [String: BrowserSyncChange], local: BrowserTabSessionSnapshot?,
    ) -> BrowserTabSessionSnapshot {
        .init(coreSyncFolderSnapshot(values: values.mapValues(\.core), local: local?.core))
    }

    static func adoptionOperations(
        local: BrowserTabSessionSnapshot, values: [String: BrowserSyncChange], deleted: Set<String>,
    ) -> [BrowserSyncFolderOperation] {
        coreSyncFolderAdoptionOperations(
            local: local.core, values: values.mapValues(\.core), deleted: Array(deleted),
            defaultSpaceTitle: BrowserSyncOutboxProjection.defaultSpaceTitle,
        )
        .map(BrowserSyncFolderOperation.init)
    }
}
