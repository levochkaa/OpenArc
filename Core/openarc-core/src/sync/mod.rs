//! Sync: the protocol's versions and limits from `openarc-sync-protocol`, which the server shares, and the
//! projections between a session and the protocol's entities and operations.

pub mod dates;
pub mod folders;
pub mod model;
pub mod outbox;
pub mod semantic;
pub mod text;

#[cfg(test)]
mod fixture_tests;

use std::collections::HashMap;
use std::sync::Arc;

use openarc_sync_protocol as protocol;

use model::*;
use outbox::{
    Baseline, CoreSyncBaseline, CoreSyncBaselineEntity, CoreSyncBaselineUpdate, CoreSyncError, CoreSyncEvent,
    CoreSyncQueuedRowIdentity, CoreSyncRemovedEntities, CoreSyncReplayMemo, ReplayState,
};

/// Push protocol versions this client and the server know.
#[uniffi::export(name = "core_sync_supported_push_versions")]
pub fn sync_supported_push_versions() -> Vec<u32> {
    protocol::SUPPORTED_PUSH_VERSIONS.iter().map(|&version| u32::from(version)).collect()
}

/// Whether automatic expiry may use `seconds` as its inactivity interval.
#[uniffi::export(name = "core_is_sync_expiry_interval")]
pub fn is_sync_expiry_interval(seconds: i64) -> bool {
    u64::try_from(seconds).is_ok_and(protocol::is_expiry_interval)
}

/// Limits the server applies to a boost, in UTF-16 code units.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncBoostLimits {
    pub host: u32,
    pub code: u32,
    pub selector: u32,
    pub selector_count: u32,
    pub title: u32,
}

#[uniffi::export(name = "core_sync_boost_limits")]
pub fn sync_boost_limits() -> CoreSyncBoostLimits {
    CoreSyncBoostLimits {
        host: protocol::BOOST_HOST_LIMIT as u32,
        code: protocol::BOOST_CODE_LIMIT as u32,
        selector: protocol::BOOST_SELECTOR_LIMIT as u32,
        selector_count: protocol::BOOST_SELECTOR_COUNT_LIMIT as u32,
        title: protocol::BOOST_TITLE_LIMIT as u32,
    }
}

// MARK: - Projections

/// The canonical v2 entities of a session. Tabs without a Space go to the default Space, titled
/// `default_space_title` in the app's language.
#[uniffi::export(name = "core_sync_canonical_changes")]
pub fn sync_canonical_changes(snapshot: CoreSessionSnapshot, default_space_title: String) -> Vec<CoreSyncChange> {
    outbox::canonical_changes(&snapshot, &default_space_title)
}

/// The v2 changes from `previous` to `snapshot`.
#[uniffi::export(name = "core_sync_changes")]
pub fn sync_changes(
    previous: Option<CoreSessionSnapshot>,
    snapshot: CoreSessionSnapshot,
    default_space_title: String,
) -> Vec<CoreSyncChange> {
    outbox::changes(previous.as_ref(), &snapshot, &default_space_title)
}

/// The v2 changes from `previous` to `snapshot`, ranked like the canonical state with the queue applied.
#[uniffi::export(name = "core_sync_rebased_changes")]
pub fn sync_rebased_changes(
    previous: Option<CoreSessionSnapshot>,
    snapshot: CoreSessionSnapshot,
    baseline: CoreSyncBaseline,
    pending: Vec<CoreQueuedMutation>,
    default_space_title: String,
) -> Vec<CoreSyncChange> {
    outbox::rebased_changes(previous.as_ref(), &snapshot, &baseline.into(), &pending, &default_space_title)
}

#[uniffi::export(name = "core_sync_replacing_rank")]
pub fn sync_replacing_rank(change: CoreSyncChange, rank: Option<f64>) -> CoreSyncChange {
    outbox::replacing_rank(&change, rank)
}

/// The positions of the session's entries the baseline's deleted keys take out.
#[uniffi::export(name = "core_sync_removed_entities")]
pub fn sync_removed_entities(snapshot: CoreSessionSnapshot, deleted_keys: Vec<String>) -> CoreSyncRemovedEntities {
    outbox::removed_entities(&snapshot, &deleted_keys.into_iter().collect())
}

/// What server events change in the baseline. `entities` holds the baseline's entities the events name;
/// the result holds them as they end up, and the keys to add to the deleted keys.
#[uniffi::export(name = "core_sync_baseline_update")]
pub fn sync_baseline_update(
    entities: HashMap<String, CoreSyncBaselineEntity>,
    events: Vec<CoreSyncEvent>,
) -> Result<CoreSyncBaselineUpdate, CoreSyncError> {
    outbox::baseline_update(entities, &events)
}

/// The live canonical entities: the baseline with the queue replayed over it.
#[uniffi::export(name = "core_sync_effective_changes")]
pub fn sync_effective_changes(
    baseline: CoreSyncBaseline,
    pending: Vec<CoreQueuedMutation>,
) -> HashMap<String, CoreSyncChange> {
    outbox::effective_changes(&baseline.into(), &pending)
}

/// `core_sync_effective_changes`, reusing `memo` when the queue only lost its head row since the last call.
#[uniffi::export(name = "core_sync_effective_changes_reusing")]
pub fn sync_effective_changes_reusing(
    baseline: CoreSyncBaseline,
    pending: Vec<CoreQueuedMutation>,
    rows: Vec<CoreSyncQueuedRowIdentity>,
    memo: Arc<CoreSyncReplayMemo>,
) -> HashMap<String, CoreSyncChange> {
    outbox::effective_changes_reusing(&baseline.into(), &pending, rows, &memo)
}

/// The session the app shows for the baseline and the queue: the v2 and v3 projection, or the v4 one
/// with folders. `rows` and `memo` let an ACK skip the replay of the rest of the queue. `None` means the
/// projection is `local` to the byte, so it need not cross back.
#[uniffi::export(name = "core_sync_projected_snapshot")]
pub fn sync_projected_snapshot(
    baseline: CoreSyncBaseline,
    pending: Vec<CoreQueuedMutation>,
    local: Option<CoreSessionSnapshot>,
    folder_sync_enabled: bool,
    rows: Option<Vec<CoreSyncQueuedRowIdentity>>,
    memo: Option<Arc<CoreSyncReplayMemo>>,
) -> Option<CoreSessionSnapshot> {
    let baseline = Baseline::from(baseline);
    let values = match (rows, memo) {
        (Some(rows), Some(memo)) => outbox::effective_changes_reusing(&baseline, &pending, rows, &memo),
        _ => outbox::effective_changes(&baseline, &pending),
    };
    let snapshot = if folder_sync_enabled {
        folders::snapshot(&values, local.as_ref())
    } else {
        outbox::snapshot(&values, local.as_ref())
    };
    match &local {
        Some(local) if outbox::identical_snapshots(&snapshot, local) => None,
        _ => Some(snapshot),
    }
}

#[uniffi::export(name = "core_sync_replay_start")]
pub fn sync_replay_start(baseline: CoreSyncBaseline, pending: Vec<CoreQueuedMutation>) -> CoreSyncReplayState {
    outbox::replay_start(&baseline.into(), &pending).into()
}

/// The state with one queued row applied.
#[uniffi::export(name = "core_sync_replay")]
pub fn sync_replay(mutation: CoreQueuedMutation, state: CoreSyncReplayState) -> CoreSyncReplayState {
    let mut state = ReplayState::from(state);
    outbox::replay(&mutation, &mut state);
    state.into()
}

#[uniffi::export(name = "core_sync_replay_result")]
pub fn sync_replay_result(state: CoreSyncReplayState, baseline: CoreSyncBaseline) -> HashMap<String, CoreSyncChange> {
    outbox::replay_result(&state.into(), &baseline.into())
}

/// Whether two replay states are equal down to string bytes and rank bits.
#[uniffi::export(name = "core_sync_replay_states_identical")]
pub fn sync_replay_states_identical(left: CoreSyncReplayState, right: CoreSyncReplayState) -> bool {
    ReplayState::from(left).is_identical(&right.into())
}

/// The v3 operations from `previous` to `snapshot`. `move_tab_ids` names the tabs a direct move acted on;
/// pass an empty list when the sessions are equal.
#[uniffi::export(name = "core_sync_semantic_operations")]
pub fn sync_semantic_operations(
    previous: Option<CoreSessionSnapshot>,
    snapshot: CoreSessionSnapshot,
    move_tab_ids: Option<Vec<String>>,
    default_space_title: String,
) -> Vec<CoreSemanticOperation> {
    semantic::operations(previous.as_ref(), &snapshot, move_tab_ids.as_deref(), &default_space_title)
}

#[uniffi::export(name = "core_sync_semantic_apply")]
pub fn sync_semantic_apply(operations: Vec<CoreSemanticOperation>, state: CoreSyncReplayState) -> CoreSyncReplayState {
    let mut state = ReplayState::from(state);
    semantic::apply(&operations, &mut state.values, &mut state.deleted);
    state.into()
}

/// The canonical v4 entities of a session, in sidebar order.
#[uniffi::export(name = "core_sync_folder_canonical_changes")]
pub fn sync_folder_canonical_changes(
    snapshot: CoreSessionSnapshot,
    default_space_title: String,
) -> Vec<CoreSyncChange> {
    folders::canonical_changes(&snapshot, &default_space_title)
}

/// The v4 operations from `previous` to `snapshot`. `move_items` names the roots a direct move acted on;
/// pass an empty list when the sessions are equal.
#[uniffi::export(name = "core_sync_folder_operations")]
pub fn sync_folder_operations(
    previous: Option<CoreSessionSnapshot>,
    snapshot: CoreSessionSnapshot,
    move_items: Option<Vec<CoreSyncEntityRef>>,
    default_space_title: String,
) -> Vec<CoreFolderOperation> {
    folders::operations(previous.as_ref(), &snapshot, move_items.as_deref(), &default_space_title)
}

#[uniffi::export(name = "core_sync_folder_apply")]
pub fn sync_folder_apply(operations: Vec<CoreFolderOperation>, state: CoreSyncReplayState) -> CoreSyncReplayState {
    let mut state = ReplayState::from(state);
    folders::apply(&operations, &mut state.values, &mut state.deleted);
    state.into()
}

/// The v4 session for canonical values.
#[uniffi::export(name = "core_sync_folder_snapshot")]
pub fn sync_folder_snapshot(
    values: HashMap<String, CoreSyncChange>,
    local: Option<CoreSessionSnapshot>,
) -> CoreSessionSnapshot {
    folders::snapshot(&values, local.as_ref())
}

/// The operations that adopt this device's local folders into canonical state that lacks them.
#[uniffi::export(name = "core_sync_folder_adoption_operations")]
pub fn sync_folder_adoption_operations(
    local: CoreSessionSnapshot,
    values: HashMap<String, CoreSyncChange>,
    deleted: Vec<String>,
    default_space_title: String,
) -> Vec<CoreFolderOperation> {
    folders::adoption_operations(&local, &values, &deleted.into_iter().collect(), &default_space_title)
}

/// Whether a v4 move would apply.
#[uniffi::export(name = "core_sync_folder_can_move")]
pub fn sync_folder_can_move(
    items: Vec<CoreSyncEntityRef>,
    destination: CoreSyncFolderDestination,
    values: HashMap<String, CoreSyncChange>,
    deleted: Vec<String>,
) -> bool {
    folders::can_move(&items, &destination, &values, &deleted.into_iter().collect())
}
