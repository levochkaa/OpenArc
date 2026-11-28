//! The outbox projection: canonical entities of a session, the acknowledged baseline, and the replay of
//! queued rows over it into the session the app shows.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use super::dates;
use super::folders;
use super::model::*;
use super::semantic;
use super::text::{order, same, same_option};

/// The canonical v2 entities of a session: its Spaces, then its tabs, ranked by position. Ordinary tabs
/// without a Space belong to the default one, titled `default_space_title`; Favorites need no Space.
pub fn canonical_changes(snapshot: &CoreSessionSnapshot, default_space_title: &str) -> Vec<CoreSyncChange> {
    let mut result = Vec::new();
    let mut spaces: Vec<(&str, &str, &str, bool)> = snapshot
        .spaces
        .iter()
        .flatten()
        .map(|space| {
            (
                space.id.as_str(),
                space.title.as_str(),
                space.system_image_name.as_str(),
                space.is_pinned_section_collapsed,
            )
        })
        .collect();
    if !spaces.iter().any(|space| space.0 == DEFAULT_SPACE_ID)
        && snapshot.tabs.iter().any(|tab| {
            tab.placement != CoreTabPlacement::App
                && same(tab.space_id.as_deref().unwrap_or(DEFAULT_SPACE_ID), DEFAULT_SPACE_ID)
        })
    {
        spaces.push((DEFAULT_SPACE_ID, default_space_title, DEFAULT_SPACE_ICON, false));
    }
    for (index, (id, title, icon, collapsed)) in spaces.into_iter().enumerate() {
        result.push(CoreSyncChange::space(
            id,
            CoreSyncSpacePayload {
                title: title.to_owned(),
                system_image_name: icon.to_owned(),
                rank: index as f64,
                is_pinned_section_collapsed: collapsed,
                selected_tab_id: None,
            },
        ));
    }
    for (index, tab) in snapshot.tabs.iter().enumerate() {
        let Some(id) = &tab.id else { continue };
        result.push(CoreSyncChange::tab(
            id,
            CoreSyncTabPayload {
                space_id: tab.space_id.clone().unwrap_or_else(|| DEFAULT_SPACE_ID.to_owned()),
                placement: tab.placement,
                rank: index as f64,
                url_string: tab.url_string.clone(),
                pinned_url_string: tab.pinned_url_string.clone(),
                title: None,
                user_title_override: tab.user_title_override.clone(),
                favicon_url_string: None,
                last_activity_at: tab.last_activity_timestamp.map(dates::format),
                pinned_folder_id: None,
            },
        ));
    }
    result
}

/// Upserts of every entity that differs, then deletes of every entity that is gone.
fn delta(before: &[CoreSyncChange], after: &[CoreSyncChange]) -> Vec<CoreSyncChange> {
    let before_by_key: HashMap<String, &CoreSyncChange> =
        before.iter().map(|change| (key_of(change), change)).collect();
    let after_keys: HashSet<String> = after.iter().map(key_of).collect();
    let mut result: Vec<CoreSyncChange> =
        after.iter().filter(|change| before_by_key.get(&key_of(change)) != Some(change)).cloned().collect();
    result.extend(
        before
            .iter()
            .filter(|change| !after_keys.contains(&key_of(change)))
            .map(|change| CoreSyncChange::deleted(change.entity_type, &change.entity_id)),
    );
    result
}

/// The v2 changes from one session to the next.
pub fn changes(
    previous: Option<&CoreSessionSnapshot>,
    snapshot: &CoreSessionSnapshot,
    title: &str,
) -> Vec<CoreSyncChange> {
    delta(
        &canonical_changes(previous.unwrap_or(&CoreSessionSnapshot::default()), title),
        &canonical_changes(snapshot, title),
    )
}

/// The v2 changes from one session to the next, ranked like the canonical state with the queue applied.
/// v2 has one rank list for Spaces and one for every tab: a list keeps those ranks until an insertion or
/// a reorder renumbers it, so metadata edits never reorder.
pub fn rebased_changes(
    previous: Option<&CoreSessionSnapshot>,
    snapshot: &CoreSessionSnapshot,
    baseline: &Baseline,
    pending: &[CoreQueuedMutation],
    title: &str,
) -> Vec<CoreSyncChange> {
    let before = canonical_changes(previous.unwrap_or(&CoreSessionSnapshot::default()), title);
    let after = canonical_changes(snapshot, title);
    let effective = effective_changes(baseline, pending);
    let ranks: HashMap<&String, f64> =
        effective.iter().filter_map(|(key, change)| change.space_or_tab_rank().map(|rank| (key, rank))).collect();
    let mut normalized = HashSet::new();
    for entity_type in [CoreSyncEntityType::Space, CoreSyncEntityType::Tab] {
        let after_ids: Vec<&str> = after
            .iter()
            .filter(|change| change.entity_type == entity_type)
            .map(|change| change.entity_id.as_str())
            .collect();
        let after_set: HashSet<&str> = after_ids.iter().copied().collect();
        let surviving: Vec<&str> = before
            .iter()
            .filter(|change| change.entity_type == entity_type && after_set.contains(change.entity_id.as_str()))
            .map(|change| change.entity_id.as_str())
            .collect();
        if surviving.len() != after_ids.len()
            || surviving.iter().zip(&after_ids).any(|(left, right)| !same(left, right))
        {
            normalized.insert(entity_type);
        }
    }
    let rank_of = |change: &CoreSyncChange| ranks.get(&key_of(change)).copied();
    delta(
        &before.iter().map(|change| replacing_rank(change, rank_of(change))).collect::<Vec<_>>(),
        &after
            .iter()
            .map(|change| {
                if normalized.contains(&change.entity_type) {
                    change.clone()
                } else {
                    replacing_rank(change, rank_of(change))
                }
            })
            .collect::<Vec<_>>(),
    )
}

/// The change with another Space or tab rank; folders and a missing rank leave it as it is.
pub fn replacing_rank(change: &CoreSyncChange, rank: Option<f64>) -> CoreSyncChange {
    let Some(rank) = rank else { return change.clone() };
    let mut result = change.clone();
    if let Some(data) = &mut result.space_data {
        data.rank = rank;
        result.tab_data = None;
        result.folder_data = None;
    } else if let Some(data) = &mut result.tab_data {
        data.rank = rank;
        result.folder_data = None;
    }
    result
}

/// Positions in a session's lists of the entries `removed_entities` takes out.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncRemovedEntities {
    pub spaces: Vec<u32>,
    pub folders: Vec<u32>,
    pub tabs: Vec<u32>,
}

/// What the server deleted from the session: deleted Spaces with their tabs and folders, deleted tabs, and
/// deleted folders with their subfolders and pinned tabs. The app drops these positions itself, so the
/// session crosses into the core once and not back.
pub fn removed_entities(snapshot: &CoreSessionSnapshot, deleted: &HashSet<String>) -> CoreSyncRemovedEntities {
    let is_deleted = |entity_type, id: &str| deleted.contains(&key(entity_type, id));
    let folders = snapshot.pinned_tab_folders.as_deref().unwrap_or_default();
    let mut deleted_folders: HashSet<&str> = folders
        .iter()
        .filter(|folder| {
            is_deleted(CoreSyncEntityType::Folder, &folder.id)
                || is_deleted(CoreSyncEntityType::Space, &folder.space_id)
                || folder
                    .parent_folder_id
                    .as_deref()
                    .is_some_and(|parent| is_deleted(CoreSyncEntityType::Folder, parent))
        })
        .map(|folder| folder.id.as_str())
        .collect();
    let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
    for folder in folders {
        if let Some(parent) = &folder.parent_folder_id {
            children.entry(parent.as_str()).or_default().push(&folder.id);
        }
    }
    let mut queue: Vec<&str> = deleted_folders.iter().copied().collect();
    let mut index = 0;
    while index < queue.len() {
        for &child in children.get(queue[index]).into_iter().flatten() {
            if deleted_folders.insert(child) {
                queue.push(child);
            }
        }
        index += 1;
    }
    let positions = |removed: Vec<bool>| -> Vec<u32> {
        removed.into_iter().enumerate().filter(|(_, removed)| *removed).map(|(index, _)| index as u32).collect()
    };
    CoreSyncRemovedEntities {
        spaces: positions(
            snapshot.spaces.iter().flatten().map(|space| is_deleted(CoreSyncEntityType::Space, &space.id)).collect(),
        ),
        folders: positions(folders.iter().map(|folder| deleted_folders.contains(folder.id.as_str())).collect()),
        tabs: positions(
            snapshot
                .tabs
                .iter()
                .map(|tab| {
                    !((tab.placement == CoreTabPlacement::App
                        || !is_deleted(CoreSyncEntityType::Space, tab.space_id.as_deref().unwrap_or(DEFAULT_SPACE_ID)))
                        && tab.id.as_deref().is_none_or(|id| !is_deleted(CoreSyncEntityType::Tab, id))
                        && (tab.placement != CoreTabPlacement::SpacePinned
                            || tab.pinned_folder_id.as_deref().is_none_or(|folder| {
                                !deleted_folders.contains(folder) && !is_deleted(CoreSyncEntityType::Folder, folder)
                            })))
                })
                .collect(),
        ),
    }
}

/// The session without what `removed_entities` names.
pub fn removing_deleted_entities(snapshot: &CoreSessionSnapshot, deleted: &HashSet<String>) -> CoreSessionSnapshot {
    let removed = removed_entities(snapshot, deleted);
    let keep = |positions: &[u32]| {
        let positions: HashSet<usize> = positions.iter().map(|&index| index as usize).collect();
        move |index: usize| !positions.contains(&index)
    };
    let (keep_space, keep_folder, keep_tab) = (keep(&removed.spaces), keep(&removed.folders), keep(&removed.tabs));
    CoreSessionSnapshot {
        spaces: snapshot.spaces.as_ref().map(|spaces| {
            spaces.iter().enumerate().filter(|(index, _)| keep_space(*index)).map(|(_, space)| space.clone()).collect()
        }),
        pinned_tab_folders: snapshot.pinned_tab_folders.as_ref().map(|folders| {
            folders
                .iter()
                .enumerate()
                .filter(|(index, _)| keep_folder(*index))
                .map(|(_, folder)| folder.clone())
                .collect()
        }),
        tabs: snapshot
            .tabs
            .iter()
            .enumerate()
            .filter(|(index, _)| keep_tab(*index))
            .map(|(_, tab)| tab.clone())
            .collect(),
    }
}

/// Whether two sessions are equal down to string bytes and number bits, local fields included.
pub fn identical_snapshots(left: &CoreSessionSnapshot, right: &CoreSessionSnapshot) -> bool {
    fn number(left: Option<f64>, right: Option<f64>) -> bool {
        left.map(f64::to_bits) == right.map(f64::to_bits)
    }
    fn list<T>(left: &Option<Vec<T>>, right: &Option<Vec<T>>, same: impl Fn(&T, &T) -> bool) -> bool {
        match (left, right) {
            (None, None) => true,
            (Some(left), Some(right)) => {
                left.len() == right.len() && left.iter().zip(right).all(|(left, right)| same(left, right))
            }
            _ => false,
        }
    }
    list(&left.spaces, &right.spaces, |left, right| {
        left.id == right.id
            && left.title == right.title
            && left.system_image_name == right.system_image_name
            && left.is_pinned_section_collapsed == right.is_pinned_section_collapsed
            && left.selected_tab_index == right.selected_tab_index
            && left.color_name == right.color_name
            && left.profile_directory == right.profile_directory
    }) && list(&left.pinned_tab_folders, &right.pinned_tab_folders, |left, right| {
        left.id == right.id
            && left.space_id == right.space_id
            && left.parent_folder_id == right.parent_folder_id
            && left.title == right.title
            && left.system_image_name == right.system_image_name
            && left.is_expanded == right.is_expanded
            && number(left.pinned_sibling_rank, right.pinned_sibling_rank)
    }) && left.tabs.len() == right.tabs.len()
        && left.tabs.iter().zip(&right.tabs).all(|(left, right)| {
            left.id == right.id
                && left.url_string == right.url_string
                && left.pinned_url_string == right.pinned_url_string
                && left.user_title_override == right.user_title_override
                && left.placement == right.placement
                && left.space_id == right.space_id
                && left.pinned_folder_id == right.pinned_folder_id
                && number(left.pinned_sibling_rank, right.pinned_sibling_rank)
                && number(left.last_activity_timestamp, right.last_activity_timestamp)
                && left.page_title == right.page_title
                && left.system_image_name == right.system_image_name
        })
}

// MARK: - Baseline

/// The server's acknowledged state: each entity with the sequence number of its last event, and the keys
/// deleted on the server or locally.
#[derive(Clone, Debug, Default)]
pub struct Baseline {
    pub entities: HashMap<String, CoreSyncBaselineEntity>,
    pub deleted: HashSet<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncBaselineEntity {
    pub server_seq: i64,
    pub change: CoreSyncChange,
}

#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncBaseline {
    pub entities: HashMap<String, CoreSyncBaselineEntity>,
    pub deleted_keys: Vec<String>,
}

impl From<CoreSyncBaseline> for Baseline {
    fn from(baseline: CoreSyncBaseline) -> Self {
        Self { entities: baseline.entities, deleted: baseline.deleted_keys.into_iter().collect() }
    }
}

impl From<Baseline> for CoreSyncBaseline {
    fn from(baseline: Baseline) -> Self {
        Self { entities: baseline.entities, deleted_keys: baseline.deleted.into_iter().collect() }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncEventSpaceData {
    pub title: Option<String>,
    pub system_image_name: Option<String>,
    pub rank: Option<f64>,
    pub is_pinned_section_collapsed: Option<bool>,
    pub selected_tab_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncEventTabData {
    pub space_id: Option<String>,
    pub placement: Option<CoreTabPlacement>,
    pub rank: Option<f64>,
    pub url_string: Option<String>,
    pub pinned_url_string: Option<String>,
    pub title: Option<String>,
    pub user_title_override: Option<String>,
    pub favicon_url_string: Option<String>,
    pub last_activity_at: Option<String>,
    pub pinned_folder_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncEventFolderData {
    pub space_id: Option<String>,
    pub parent_folder_id: Option<String>,
    pub title: Option<String>,
    pub system_image_name: Option<String>,
    pub rank: Option<f64>,
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreSyncEventData {
    Space {
        data: CoreSyncEventSpaceData,
    },
    Tab {
        data: CoreSyncEventTabData,
    },
    Folder {
        data: CoreSyncEventFolderData,
    },
    /// A delete's data, a boost, or anything else.
    Other,
}

/// A server event, as far as the baseline reads it.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncEvent {
    pub server_seq: i64,
    pub entity_type: String,
    pub entity_id: String,
    pub op: String,
    pub data: CoreSyncEventData,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreSyncError {
    /// An event names an unknown entity or operation, or lacks a required field.
    #[error("invalid sync event")]
    InvalidEvent,
}

impl Baseline {
    /// Applies server events in sequence order. A replayed event older than the entity's last one is
    /// skipped, and a server delete is permanent: no later upsert of that identity applies.
    pub fn apply(&mut self, events: &[CoreSyncEvent]) -> Result<(), CoreSyncError> {
        let mut ordered: Vec<&CoreSyncEvent> = events.iter().collect();
        ordered.sort_by_key(|event| event.server_seq);
        for event in ordered {
            let (Some(entity_type), Some(op)) =
                (CoreSyncEntityType::from_raw(&event.entity_type), op_from_raw(&event.op))
            else {
                return Err(CoreSyncError::InvalidEvent);
            };
            if event.server_seq < 0 {
                return Err(CoreSyncError::InvalidEvent);
            }
            let key = key(entity_type, &event.entity_id);
            let known = self.entities.get(&key);
            if event.server_seq <= known.map_or(-1, |entity| entity.server_seq) {
                continue;
            }
            if op == CoreSyncOp::Delete {
                let server_seq = event.server_seq.max(known.map_or(0, |entity| entity.server_seq));
                self.deleted.insert(key.clone());
                self.entities.insert(
                    key,
                    CoreSyncBaselineEntity {
                        server_seq,
                        change: CoreSyncChange::deleted(entity_type, &event.entity_id),
                    },
                );
                continue;
            }
            if known.is_some_and(|entity| entity.change.op == CoreSyncOp::Delete) {
                continue;
            }
            let change = match (entity_type, &event.data) {
                (CoreSyncEntityType::Space, CoreSyncEventData::Space { data }) => {
                    let (Some(title), Some(icon), Some(rank), Some(collapsed)) =
                        (&data.title, &data.system_image_name, data.rank, data.is_pinned_section_collapsed)
                    else {
                        return Err(CoreSyncError::InvalidEvent);
                    };
                    CoreSyncChange::space(
                        &event.entity_id,
                        CoreSyncSpacePayload {
                            title: title.clone(),
                            system_image_name: icon.clone(),
                            rank,
                            is_pinned_section_collapsed: collapsed,
                            selected_tab_id: data.selected_tab_id.clone(),
                        },
                    )
                }
                (CoreSyncEntityType::Tab, CoreSyncEventData::Tab { data }) => {
                    let (Some(space_id), Some(placement), Some(rank), Some(url)) =
                        (&data.space_id, data.placement, data.rank, &data.url_string)
                    else {
                        return Err(CoreSyncError::InvalidEvent);
                    };
                    CoreSyncChange::tab(
                        &event.entity_id,
                        CoreSyncTabPayload {
                            space_id: space_id.clone(),
                            placement,
                            rank,
                            url_string: url.clone(),
                            pinned_url_string: data.pinned_url_string.clone(),
                            title: data.title.clone(),
                            user_title_override: data.user_title_override.clone(),
                            favicon_url_string: data.favicon_url_string.clone(),
                            last_activity_at: data.last_activity_at.clone(),
                            pinned_folder_id: data.pinned_folder_id.clone(),
                        },
                    )
                }
                (CoreSyncEntityType::Folder, CoreSyncEventData::Folder { data }) => {
                    let (Some(space_id), Some(title), Some(rank)) = (&data.space_id, &data.title, data.rank) else {
                        return Err(CoreSyncError::InvalidEvent);
                    };
                    CoreSyncChange::folder(
                        &event.entity_id,
                        CoreSyncFolderPayload {
                            space_id: space_id.clone(),
                            parent_folder_id: data.parent_folder_id.clone(),
                            title: title.clone(),
                            system_image_name: data.system_image_name.clone(),
                            rank,
                        },
                    )
                }
                _ => return Err(CoreSyncError::InvalidEvent),
            };
            self.entities.insert(key, CoreSyncBaselineEntity { server_seq: event.server_seq, change });
        }
        Ok(())
    }
}

/// What server events change in a baseline: the entities they name, as they end up, and the keys they
/// delete. `Baseline::apply` reads only the entities events name, so the app sends just those.
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncBaselineUpdate {
    pub entities: HashMap<String, CoreSyncBaselineEntity>,
    pub deleted_keys: Vec<String>,
}

/// The update `events` make to a baseline whose entities named by the events are `entities`.
pub fn baseline_update(
    entities: HashMap<String, CoreSyncBaselineEntity>,
    events: &[CoreSyncEvent],
) -> Result<CoreSyncBaselineUpdate, CoreSyncError> {
    let mut baseline = Baseline { entities, deleted: HashSet::new() };
    baseline.apply(events)?;
    Ok(CoreSyncBaselineUpdate { entities: baseline.entities, deleted_keys: baseline.deleted.into_iter().collect() })
}

fn op_from_raw(raw: &str) -> Option<CoreSyncOp> {
    match raw {
        "upsert" => Some(CoreSyncOp::Upsert),
        "delete" => Some(CoreSyncOp::Delete),
        _ => None,
    }
}

// MARK: - Replay

/// Replay state: canonical values with the replayed rows applied, and the keys hidden so far.
#[derive(Clone, Debug, Default)]
pub struct ReplayState {
    pub values: HashMap<String, CoreSyncChange>,
    pub deleted: HashSet<String>,
}

impl ReplayState {
    /// Equal down to string bytes and rank bits, so replaying the same rows from either state yields the
    /// same bytes. `==` accepts strings that differ only in Unicode normalization.
    pub fn is_identical(&self, other: &Self) -> bool {
        self.deleted == other.deleted
            && self.values.len() == other.values.len()
            && self.values.iter().all(|(key, value)| other.values.get(key).is_some_and(|other| identical(value, other)))
    }
}

impl From<CoreSyncReplayState> for ReplayState {
    fn from(state: CoreSyncReplayState) -> Self {
        Self { values: state.values, deleted: state.deleted.into_iter().collect() }
    }
}

impl From<ReplayState> for CoreSyncReplayState {
    fn from(state: ReplayState) -> Self {
        Self { values: state.values, deleted: state.deleted.into_iter().collect() }
    }
}

/// Local tombstones are recorded before debounce, including deletes later in this queue. Their preceding
/// creates and move-outs replay first. Server tombstones are effective from the start.
pub fn replay_start(baseline: &Baseline, pending: &[CoreQueuedMutation]) -> ReplayState {
    let values: HashMap<String, CoreSyncChange> =
        baseline.entities.iter().map(|(key, entity)| (key.clone(), entity.change.clone())).collect();
    let mut pending_deletes = HashSet::new();
    for mutation in pending {
        match mutation {
            CoreQueuedMutation::Legacy { changes } => {
                pending_deletes.extend(changes.iter().filter(|change| change.op == CoreSyncOp::Delete).map(key_of));
            }
            CoreQueuedMutation::Semantic { operations } => {
                pending_deletes.extend(operations.iter().filter_map(|operation| match operation {
                    CoreSemanticOperation::DeleteSpace { id } => Some(key(CoreSyncEntityType::Space, id)),
                    CoreSemanticOperation::DeleteTab { id } => Some(key(CoreSyncEntityType::Tab, id)),
                    _ => None,
                }));
            }
            CoreQueuedMutation::Folders { operations } => {
                pending_deletes.extend(operations.iter().filter_map(|operation| match operation {
                    CoreFolderOperation::DeleteSpace { id } => Some(key(CoreSyncEntityType::Space, id)),
                    CoreFolderOperation::DeleteTab { id } => Some(key(CoreSyncEntityType::Tab, id)),
                    CoreFolderOperation::DeleteFolder { id } => Some(key(CoreSyncEntityType::Folder, id)),
                    _ => None,
                }));
            }
            CoreQueuedMutation::Other => {}
        }
    }
    let mut deleted: HashSet<String> = baseline.deleted.difference(&pending_deletes).cloned().collect();
    deleted.extend(values.iter().filter(|(_, value)| value.op == CoreSyncOp::Delete).map(|(key, _)| key.clone()));
    ReplayState { values, deleted }
}

/// Applies one queued row. The result depends only on `state` and the row.
pub fn replay(mutation: &CoreQueuedMutation, state: &mut ReplayState) {
    match mutation {
        CoreQueuedMutation::Legacy { changes } => {
            for change in changes.iter().filter(|change| change.op == CoreSyncOp::Upsert) {
                let change_key = key_of(change);
                if state.deleted.contains(&change_key) {
                    continue;
                }
                if let Some(tab) = &change.tab_data
                    && tab.placement != CoreTabPlacement::App
                    && state.deleted.contains(&key(CoreSyncEntityType::Space, &tab.space_id))
                {
                    // A stale full record cannot move a canonical survivor back into a deleted parent.
                    // New stale children are deleted.
                    if let Some(current) = state.values.get(&change_key).and_then(|value| value.tab_data.as_ref())
                        && (!same(&current.space_id, &tab.space_id) || current.placement == CoreTabPlacement::App)
                    {
                        continue;
                    }
                    state.deleted.insert(change_key);
                    continue;
                }
                let preserved = preserving_activity(change, state.values.get(&change_key));
                state.values.insert(change_key, preserved);
            }
            // The v2 server applies upserts first, then deletes, without rank normalization. Its parent
            // cascade is permanent.
            for change in changes.iter().filter(|change| change.op == CoreSyncOp::Delete) {
                state.deleted.insert(key_of(change));
                if change.entity_type == CoreSyncEntityType::Space {
                    let children: Vec<String> = state
                        .values
                        .values()
                        .filter(|child| {
                            child.tab_data.as_ref().is_some_and(|tab| {
                                tab.placement != CoreTabPlacement::App && same(&tab.space_id, &change.entity_id)
                            })
                        })
                        .map(key_of)
                        .collect();
                    state.deleted.extend(children);
                }
            }
        }
        CoreQueuedMutation::Semantic { operations } => {
            semantic::apply(operations, &mut state.values, &mut state.deleted)
        }
        CoreQueuedMutation::Folders { operations } => folders::apply(operations, &mut state.values, &mut state.deleted),
        // Expiry rows leave live state alone until the server answers; boosts project elsewhere.
        CoreQueuedMutation::Other => {}
    }
}

pub fn replay_result(state: &ReplayState, baseline: &Baseline) -> HashMap<String, CoreSyncChange> {
    state
        .values
        .iter()
        .filter(|(key, value)| {
            value.op == CoreSyncOp::Upsert && !state.deleted.contains(*key) && !baseline.deleted.contains(*key)
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// The live canonical entities: the baseline with the queue replayed over it.
pub fn effective_changes(baseline: &Baseline, pending: &[CoreQueuedMutation]) -> HashMap<String, CoreSyncChange> {
    let mut state = replay_start(baseline, pending);
    for mutation in pending {
        replay(mutation, &mut state);
    }
    replay_result(&state, baseline)
}

/// One stored queue row as bytes. Rows that decode to equal values can still differ in bytes, for
/// example in Unicode normalization.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncQueuedRowIdentity {
    pub protocol_version: i64,
    pub payload: Vec<u8>,
}

#[derive(Default)]
struct MemoState {
    rows: Vec<CoreSyncQueuedRowIdentity>,
    head: Option<ReplayState>,
    end: Option<ReplayState>,
    reuses: u64,
}

/// The last queue replay, kept so an ACK need not replay the rest of the queue. It holds only facts
/// about the pure replay: for the exact rows in `rows`, the state after the first row and the state after
/// all of them, reached from one start. A rolled-back transaction, another account or another writer can
/// make it useless, never wrong: reuse also requires a byte-identical start.
#[derive(Default, uniffi::Object)]
pub struct CoreSyncReplayMemo {
    state: Mutex<MemoState>,
}

#[uniffi::export]
impl CoreSyncReplayMemo {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::default()
    }

    /// How many replays this memo skipped.
    pub fn reuses(&self) -> u64 {
        self.state.lock().unwrap_or_else(|poison| poison.into_inner()).reuses
    }
}

/// `effective_changes`, reusing the memo's end state when the start equals, byte for byte, the state it
/// reached after the first row of a queue whose remaining rows are `rows`. The start state already holds
/// the tombstone rule for exactly those rows, so the comparison covers deletes that are still queued.
pub fn effective_changes_reusing(
    baseline: &Baseline,
    pending: &[CoreQueuedMutation],
    rows: Vec<CoreSyncQueuedRowIdentity>,
    memo: &CoreSyncReplayMemo,
) -> HashMap<String, CoreSyncChange> {
    assert_eq!(rows.len(), pending.len(), "every queued row needs its identity");
    let start = replay_start(baseline, pending);
    let mut memo = memo.state.lock().unwrap_or_else(|poison| poison.into_inner());
    if let (Some(head), Some(end)) = (&memo.head, &memo.end)
        && memo.rows.len() == rows.len() + 1
        && memo.rows[1..] == rows[..]
        && head.is_identical(&start)
    {
        let end = end.clone();
        memo.reuses += 1;
        let head = pending.first().map(|first| {
            let mut next = start.clone();
            replay(first, &mut next);
            next
        });
        memo.remember(rows, head, end.clone());
        return replay_result(&end, baseline);
    }
    let mut state = start;
    let mut head = None;
    for (index, mutation) in pending.iter().enumerate() {
        replay(mutation, &mut state);
        if index == 0 {
            head = Some(state.clone());
        }
    }
    let result = replay_result(&state, baseline);
    memo.remember(rows, head, state);
    result
}

impl MemoState {
    fn remember(&mut self, rows: Vec<CoreSyncQueuedRowIdentity>, head: Option<ReplayState>, end: ReplayState) {
        // An empty queue has nothing to skip; drop the states.
        let empty = rows.is_empty();
        self.rows = rows;
        self.head = if empty { None } else { head };
        self.end = if empty { None } else { Some(end) };
    }
}

fn preserving_activity(change: &CoreSyncChange, previous: Option<&CoreSyncChange>) -> CoreSyncChange {
    let Some(data) = &change.tab_data else { return change.clone() };
    let previous_activity =
        previous.and_then(|previous| previous.tab_data.as_ref()).and_then(|data| data.last_activity_at.as_deref());
    let activity = dates::latest(previous_activity, data.last_activity_at.as_deref());
    if same_option(activity, data.last_activity_at.as_deref()) {
        return change.clone();
    }
    let mut result = change.clone();
    result.space_data = None;
    result.folder_data = None;
    if let Some(data) = &mut result.tab_data {
        data.last_activity_at = activity.map(str::to_owned);
    }
    result
}

// MARK: - The session from canonical state

/// The session the app shows for the live canonical entities, keeping this device's local data (titles,
/// icons, colors, folder membership of pinned tabs that stay in their Space) from `local`.
pub fn snapshot(values: &HashMap<String, CoreSyncChange>, local: Option<&CoreSessionSnapshot>) -> CoreSessionSnapshot {
    let mut space_changes: Vec<(&CoreSyncChange, &CoreSyncSpacePayload)> = values
        .values()
        .filter(|change| change.entity_type == CoreSyncEntityType::Space)
        .filter_map(|change| change.space_data.as_ref().map(|data| (change, data)))
        .collect();
    space_changes.sort_by(|left, right| rank_then_id(left.1.rank, &left.0.entity_id, right.1.rank, &right.0.entity_id));
    let space_order: HashMap<&str, usize> =
        space_changes.iter().enumerate().map(|(index, (change, _))| (change.entity_id.as_str(), index)).collect();
    let local_tabs = first_by_id(local.map(|local| local.tabs.as_slice()).unwrap_or_default());
    let mut tab_changes: Vec<(&CoreSyncChange, &CoreSyncTabPayload)> = values
        .values()
        .filter(|change| change.entity_type == CoreSyncEntityType::Tab)
        .filter_map(|change| change.tab_data.as_ref().map(|data| (change, data)))
        .filter(|(_, data)| data.placement == CoreTabPlacement::App || space_order.contains_key(data.space_id.as_str()))
        .collect();
    // v3 ranks belong to one sidebar list, never to the flattened tab array.
    tab_changes.sort_by(|(left, left_data), (right, right_data)| {
        let left_app = left_data.placement == CoreTabPlacement::App;
        let right_app = right_data.placement == CoreTabPlacement::App;
        if left_app != right_app {
            return right_app.cmp(&left_app);
        }
        if !left_app {
            let left_space = space_order[left_data.space_id.as_str()];
            let right_space = space_order[right_data.space_id.as_str()];
            if left_space != right_space {
                return left_space.cmp(&right_space);
            }
            if left_data.placement != right_data.placement {
                let left_pinned = left_data.placement == CoreTabPlacement::SpacePinned;
                return if left_pinned { std::cmp::Ordering::Less } else { std::cmp::Ordering::Greater };
            }
        }
        rank_then_id(left_data.rank, &left.entity_id, right_data.rank, &right.entity_id)
    });
    let tabs: Vec<CoreTabSnapshot> = tab_changes
        .into_iter()
        .map(|(change, data)| {
            let previous = local_tabs.get(change.entity_id.as_str());
            let pinned = data.placement == CoreTabPlacement::SpacePinned;
            let stays = pinned
                && previous.is_some_and(|previous| same_option(previous.space_id.as_deref(), Some(&data.space_id)));
            CoreTabSnapshot {
                id: Some(change.entity_id.clone()),
                url_string: data.url_string.clone(),
                pinned_url_string: if pinned { data.pinned_url_string.clone() } else { None },
                user_title_override: data.user_title_override.clone(),
                placement: data.placement,
                space_id: Some(data.space_id.clone()),
                pinned_folder_id: if stays {
                    previous.and_then(|previous| previous.pinned_folder_id.clone())
                } else {
                    None
                },
                pinned_sibling_rank: if stays {
                    previous.and_then(|previous| previous.pinned_sibling_rank)
                } else {
                    None
                },
                last_activity_timestamp: dates::projected_timestamp(
                    data.last_activity_at.as_deref(),
                    previous.and_then(|previous| previous.last_activity_timestamp),
                ),
                // Titles and icons are local; keep this device's.
                page_title: previous.and_then(|previous| previous.page_title.clone()),
                system_image_name: previous.and_then(|previous| previous.system_image_name.clone()),
            }
        })
        .collect();
    let spaces: Vec<CoreSpaceSnapshot> =
        space_changes.iter().map(|(change, data)| space_snapshot(change, data, local, &tabs)).collect();
    let space_ids: HashSet<&str> = space_changes.iter().map(|(change, _)| change.entity_id.as_str()).collect();
    CoreSessionSnapshot {
        spaces: if spaces.is_empty() { None } else { Some(spaces) },
        pinned_tab_folders: local.and_then(|local| local.pinned_tab_folders.as_ref()).map(|folders| {
            folders.iter().filter(|folder| space_ids.contains(folder.space_id.as_str())).cloned().collect()
        }),
        tabs,
    }
}

/// The Space as the app shows it: synced fields, this device's color and profile, and the selection
/// carried over to the same tab when it is still in the Space.
pub fn space_snapshot(
    change: &CoreSyncChange,
    data: &CoreSyncSpacePayload,
    local: Option<&CoreSessionSnapshot>,
    tabs: &[CoreTabSnapshot],
) -> CoreSpaceSnapshot {
    let previous = local
        .and_then(|local| local.spaces.as_ref())
        .and_then(|spaces| spaces.iter().find(|space| space.id == change.entity_id));
    let previous_tabs =
        sidebar_tab_ids(local.map(|local| local.tabs.as_slice()).unwrap_or_default(), &change.entity_id);
    let selected = previous
        .and_then(|space| space.selected_tab_index)
        .and_then(|index| usize::try_from(index).ok())
        .and_then(|index| previous_tabs.get(index).copied().flatten());
    let current_tabs = sidebar_tab_ids(tabs, &change.entity_id);
    CoreSpaceSnapshot {
        id: change.entity_id.clone(),
        title: data.title.clone(),
        system_image_name: data.system_image_name.clone(),
        is_pinned_section_collapsed: data.is_pinned_section_collapsed,
        selected_tab_index: selected.and_then(|selected| {
            current_tabs.iter().position(|id| same_option(*id, Some(selected))).map(|index| index as i64)
        }),
        // Colors are local; keep this device's.
        color_name: previous.and_then(|space| space.color_name.clone()),
        profile_directory: previous.and_then(|space| space.profile_directory.clone()),
    }
}

/// The IDs of a Space's sidebar tabs in order, pinned then temporary, with a slot for each tab without
/// an ID. Favorites are global and never selected through a Space.
fn sidebar_tab_ids<'a>(tabs: &'a [CoreTabSnapshot], space_id: &str) -> Vec<Option<&'a str>> {
    let mut result = Vec::new();
    for placement in [CoreTabPlacement::SpacePinned, CoreTabPlacement::Temporary] {
        for tab in tabs.iter().filter(|tab| tab.placement == placement) {
            if tab.space_id.as_deref().unwrap_or(DEFAULT_SPACE_ID) == space_id {
                result.push(tab.id.as_deref());
            }
        }
    }
    result
}

pub fn first_by_id(tabs: &[CoreTabSnapshot]) -> HashMap<&str, &CoreTabSnapshot> {
    let mut result = HashMap::new();
    for tab in tabs {
        if let Some(id) = &tab.id {
            result.entry(id.as_str()).or_insert(tab);
        }
    }
    result
}

fn rank_then_id(left_rank: f64, left_id: &str, right_rank: f64, right_id: &str) -> std::cmp::Ordering {
    if left_rank == right_rank {
        order(left_id, right_id)
    } else if left_rank < right_rank {
        std::cmp::Ordering::Less
    } else {
        std::cmp::Ordering::Greater
    }
}

// MARK: - Byte identity

fn identical_option(left: &Option<String>, right: &Option<String>) -> bool {
    left == right
}

fn identical(left: &CoreSyncChange, right: &CoreSyncChange) -> bool {
    if left.entity_type != right.entity_type || left.op != right.op || left.entity_id != right.entity_id {
        return false;
    }
    let spaces = match (&left.space_data, &right.space_data) {
        (None, None) => true,
        (Some(left), Some(right)) => {
            left.title == right.title
                && left.system_image_name == right.system_image_name
                && left.rank.to_bits() == right.rank.to_bits()
                && left.is_pinned_section_collapsed == right.is_pinned_section_collapsed
                && identical_option(&left.selected_tab_id, &right.selected_tab_id)
        }
        _ => false,
    };
    let tabs = match (&left.tab_data, &right.tab_data) {
        (None, None) => true,
        (Some(left), Some(right)) => {
            left.space_id == right.space_id
                && left.placement == right.placement
                && left.rank.to_bits() == right.rank.to_bits()
                && left.url_string == right.url_string
                && identical_option(&left.pinned_url_string, &right.pinned_url_string)
                && identical_option(&left.title, &right.title)
                && identical_option(&left.user_title_override, &right.user_title_override)
                && identical_option(&left.favicon_url_string, &right.favicon_url_string)
                && identical_option(&left.last_activity_at, &right.last_activity_at)
                && identical_option(&left.pinned_folder_id, &right.pinned_folder_id)
        }
        _ => false,
    };
    let folders = match (&left.folder_data, &right.folder_data) {
        (None, None) => true,
        (Some(left), Some(right)) => {
            left.space_id == right.space_id
                && identical_option(&left.parent_folder_id, &right.parent_folder_id)
                && left.title == right.title
                && identical_option(&left.system_image_name, &right.system_image_name)
                && left.rank.to_bits() == right.rank.to_bits()
        }
        _ => false,
    };
    spaces && tabs && folders
}
