//! Protocol version 4: typed sibling lists with pinned folders, and moves of whole subtrees.
//!
//! A move intent names the roots the user acted on; without one, a deterministic minimal move set follows
//! from relative order.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use super::dates;
use super::model::*;
use super::outbox::{self, first_by_id, space_snapshot};
use super::semantic::{following_anchors, home_patch, longest_increasing_subsequence, space_patch};
use super::text::{order_utf16, same, same_option};

type Ref = CoreSyncEntityRef;
type Values = HashMap<String, CoreSyncChange>;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Container {
    Spaces,
    Apps,
    Temporary(String),
    Pinned(String, Option<String>),
}

impl Container {
    fn of_destination(destination: &CoreSyncFolderDestination) -> Self {
        match destination {
            CoreSyncFolderDestination::Spaces => Self::Spaces,
            CoreSyncFolderDestination::Tabs { placement: CoreTabPlacement::App, .. } => Self::Apps,
            CoreSyncFolderDestination::Tabs { space_id, placement: CoreTabPlacement::Temporary, .. } => {
                Self::Temporary(space_id.clone())
            }
            CoreSyncFolderDestination::Tabs {
                space_id,
                placement: CoreTabPlacement::SpacePinned,
                pinned_folder_id,
            } => Self::Pinned(space_id.clone(), pinned_folder_id.clone()),
        }
    }

    fn of(change: &CoreSyncChange) -> Self {
        Self::of_destination(&destination(change))
    }
}

struct Plan {
    items: Vec<Ref>,
    kept: HashSet<Ref>,
    created: HashSet<Ref>,
}

fn destination(change: &CoreSyncChange) -> CoreSyncFolderDestination {
    if let Some(folder) = &change.folder_data {
        return CoreSyncFolderDestination::Tabs {
            space_id: folder.space_id.clone(),
            placement: CoreTabPlacement::SpacePinned,
            pinned_folder_id: folder.parent_folder_id.clone(),
        };
    }
    if let Some(tab) = &change.tab_data {
        return CoreSyncFolderDestination::Tabs {
            space_id: tab.space_id.clone(),
            placement: tab.placement,
            pinned_folder_id: tab.pinned_folder_id.clone(),
        };
    }
    CoreSyncFolderDestination::Spaces
}

fn same_destination(left: &CoreSyncFolderDestination, right: &CoreSyncFolderDestination) -> bool {
    match (left, right) {
        (CoreSyncFolderDestination::Spaces, CoreSyncFolderDestination::Spaces) => true,
        (
            CoreSyncFolderDestination::Tabs { space_id, placement, pinned_folder_id },
            CoreSyncFolderDestination::Tabs {
                space_id: other_space,
                placement: other_placement,
                pinned_folder_id: other_folder,
            },
        ) => {
            same(space_id, other_space)
                && placement == other_placement
                && same_option(pinned_folder_id.as_deref(), other_folder.as_deref())
        }
        _ => false,
    }
}

fn rank(change: &CoreSyncChange) -> f64 {
    change
        .space_data
        .as_ref()
        .map(|data| data.rank)
        .or(change.tab_data.as_ref().map(|data| data.rank))
        .or(change.folder_data.as_ref().map(|data| data.rank))
        .unwrap_or(0.0)
}

fn by_rank_then_key(left: &CoreSyncChange, right: &CoreSyncChange) -> Ordering {
    let (left_rank, right_rank) = (rank(left), rank(right));
    if left_rank == right_rank {
        order_utf16(&key_of(left), &key_of(right))
    } else if left_rank < right_rank {
        Ordering::Less
    } else {
        Ordering::Greater
    }
}

/// Whether a move would apply, with the same validation as the replay, including valid no-op moves.
pub fn can_move(
    items: &[Ref],
    destination: &CoreSyncFolderDestination,
    values: &Values,
    deleted: &HashSet<String>,
) -> bool {
    move_context(items, destination, values, deleted).is_some()
}

/// The canonical v4 entities of a session: Spaces, Favorites, then each Space's pinned tree depth first
/// and its temporary tabs. Legacy sessions give a folder its place by its first descendant tab; empty
/// folders append in saved folder order.
pub fn canonical_changes(snapshot: &CoreSessionSnapshot, default_space_title: &str) -> Vec<CoreSyncChange> {
    let base = outbox::canonical_changes(snapshot, default_space_title);
    let local_tabs = first_by_id(&snapshot.tabs);
    let snapshot_folders = snapshot.pinned_tab_folders.as_deref().unwrap_or_default();
    let mut folders: HashMap<&str, &CoreFolderSnapshot> = HashMap::new();
    for folder in snapshot_folders {
        folders.entry(folder.id.as_str()).or_insert(folder);
    }
    let mut values: Values = HashMap::new();
    for change in &base {
        values.entry(key_of(change)).or_insert_with(|| change.clone());
    }
    for folder in snapshot_folders {
        values.insert(
            key(CoreSyncEntityType::Folder, &folder.id),
            CoreSyncChange::folder(
                &folder.id,
                CoreSyncFolderPayload {
                    space_id: folder.space_id.clone(),
                    parent_folder_id: folder.parent_folder_id.clone(),
                    title: folder.title.clone(),
                    system_image_name: folder.system_image_name.clone(),
                    rank: folder.pinned_sibling_rank.unwrap_or(0.0),
                },
            ),
        );
    }
    for change in &base {
        let (Some(data), Some(tab)) = (&change.tab_data, local_tabs.get(change.entity_id.as_str())) else { continue };
        let mut data = data.clone();
        data.pinned_folder_id =
            if data.placement == CoreTabPlacement::SpacePinned { tab.pinned_folder_id.clone() } else { None };
        values.insert(key_of(change), replacing_tab(change, data));
    }
    let mut inferred: HashMap<Container, Vec<Ref>> = HashMap::new();
    let mut seen: HashSet<Ref> = HashSet::new();
    let append =
        |reference: Ref, inferred: &mut HashMap<Container, Vec<Ref>>, seen: &mut HashSet<Ref>, values: &Values| {
            if !seen.insert(reference.clone()) {
                return;
            }
            if let Some(change) = values.get(&reference.key()) {
                inferred.entry(Container::of(change)).or_default().push(reference);
            }
        };
    let append_ancestors =
        |id: Option<&str>, inferred: &mut HashMap<Container, Vec<Ref>>, seen: &mut HashSet<Ref>, values: &Values| {
            let mut path = Vec::new();
            let mut visited = HashSet::new();
            let mut current = id;
            while let Some(folder_id) = current
                && visited.insert(folder_id)
                && let Some(folder) = folders.get(folder_id)
            {
                path.push(folder_id);
                current = folder.parent_folder_id.as_deref();
            }
            for folder_id in path.into_iter().rev() {
                append(Ref::new(CoreSyncEntityType::Folder, folder_id), inferred, seen, values);
            }
        };
    for tab in snapshot.tabs.iter().filter(|tab| tab.placement == CoreTabPlacement::SpacePinned) {
        append_ancestors(tab.pinned_folder_id.as_deref(), &mut inferred, &mut seen, &values);
        if let Some(id) = &tab.id {
            append(Ref::new(CoreSyncEntityType::Tab, id), &mut inferred, &mut seen, &values);
        }
    }
    for folder in snapshot_folders {
        append_ancestors(Some(&folder.id), &mut inferred, &mut seen, &values);
    }
    for references in inferred.values() {
        for (index, reference) in references.iter().enumerate() {
            let Some(change) = values.get(&reference.key()) else { continue };
            let explicit = if reference.entity_type == CoreSyncEntityType::Folder {
                folders.get(reference.entity_id.as_str()).and_then(|folder| folder.pinned_sibling_rank)
            } else {
                local_tabs.get(reference.entity_id.as_str()).and_then(|tab| tab.pinned_sibling_rank)
            };
            let ranked = ranked(change, explicit.unwrap_or(index as f64));
            values.insert(reference.key(), ranked);
        }
    }
    ordered_values(&values)
}

/// The operations that turn `previous` into `snapshot`. `move_items` names the roots a direct move acted
/// on; pass an empty list when the sessions are equal.
pub fn operations(
    previous: Option<&CoreSessionSnapshot>,
    snapshot: &CoreSessionSnapshot,
    move_items: Option<&[Ref]>,
    default_space_title: &str,
) -> Vec<CoreFolderOperation> {
    let before = canonical_changes(previous.unwrap_or(&CoreSessionSnapshot::default()), default_space_title);
    let after = canonical_changes(snapshot, default_space_title);
    let old = first_by_key(&before);
    let next = first_by_key(&after);
    let mut old_groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    for change in &before {
        old_groups.entry(Container::of(change)).or_default().push(change);
    }
    let mut groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    for change in &after {
        groups.entry(Container::of(change)).or_default().push(change);
    }
    let hints: Option<HashSet<&Ref>> = move_items.map(|items| items.iter().collect());
    let mut plans = Vec::new();
    let mut visited = HashSet::new();
    for change in &after {
        let list = Container::of(change);
        if !visited.insert(list.clone()) {
            continue;
        }
        let items: Vec<Ref> = groups[&list].iter().map(|change| Ref::of(change)).collect();
        let mut previous_positions: HashMap<Ref, usize> = HashMap::new();
        for (index, change) in old_groups.get(&list).into_iter().flatten().enumerate() {
            previous_positions.entry(Ref::of(change)).or_insert(index);
        }
        let kept: HashSet<Ref> = match &hints {
            Some(hints) => {
                items.iter().filter(|item| !hints.contains(item) && old.contains_key(&item.key())).cloned().collect()
            }
            None => {
                let candidates: Vec<(&Ref, usize)> =
                    items.iter().filter_map(|item| previous_positions.get(item).map(|&index| (item, index))).collect();
                longest_increasing_subsequence(&candidates).into_iter().cloned().collect()
            }
        };
        let created = items.iter().filter(|item| !old.contains_key(&item.key())).cloned().collect();
        plans.push(Plan { items, kept, created });
    }
    let folder_moves: HashSet<&str> = plans
        .iter()
        .flat_map(|plan| {
            plan.items.iter().filter(|item| {
                item.entity_type == CoreSyncEntityType::Folder
                    && !plan.kept.contains(*item)
                    && !plan.created.contains(*item)
            })
        })
        .map(|item| item.entity_id.as_str())
        .collect();
    // A cross-Space folder action changes every descendant's saved Space ID, but the server moves the
    // current subtree, including children this device has not seen.
    let carried: HashSet<Ref> = after
        .iter()
        .filter_map(|change| {
            let previous = old.get(&key_of(change))?;
            let parent = parent_of(change);
            if !same_option(parent, parent_of(previous)) {
                return None;
            }
            let parent = parent?;
            ancestors(Some(parent), &next).iter().any(|id| folder_moves.contains(id.as_str())).then(|| Ref::of(change))
        })
        .collect();
    for plan in &mut plans {
        plan.kept.extend(carried.iter().cloned());
    }
    let mut operations = Vec::new();
    let mut home_patches = Vec::new();
    // Parent lists come before child lists in the canonical order.
    for plan in &plans {
        let following = following_anchors(&plan.items, &plan.kept);
        let mut preceding: Option<&Ref> = None;
        for (index, item) in plan.items.iter().enumerate() {
            if plan.created.contains(item)
                && let Some(change) = next.get(&item.key())
            {
                operations.push(create_operation(change, following[index].cloned(), preceding.cloned()));
            }
            if plan.kept.contains(item) || plan.created.contains(item) {
                preceding = Some(item);
            }
        }
    }
    for change in &after {
        let Some(previous) = old.get(&key_of(change)) else { continue };
        if let (Some(data), Some(was)) = (&change.space_data, &previous.space_data) {
            let fields = space_patch(&data.title, &data.system_image_name, data.is_pinned_section_collapsed, was);
            if !fields.is_empty() {
                operations.push(CoreFolderOperation::PatchSpace { id: change.entity_id.clone(), fields });
            }
        } else if let (Some(data), Some(was)) = (&change.folder_data, &previous.folder_data) {
            let fields = CoreSyncFolderPatch {
                title: (!same(&data.title, &was.title)).then(|| data.title.clone()),
                system_image_name: CorePatch::from(was.system_image_name.as_deref(), data.system_image_name.as_deref()),
            };
            if !fields.is_empty() {
                operations.push(CoreFolderOperation::PatchFolder { id: change.entity_id.clone(), fields });
            }
        } else if let (Some(data), Some(was)) = (&change.tab_data, &previous.tab_data) {
            let fields = CoreSyncTabPatch {
                url_string: (!same(&data.url_string, &was.url_string)).then(|| data.url_string.clone()),
                user_title_override: CorePatch::from(
                    was.user_title_override.as_deref(),
                    data.user_title_override.as_deref(),
                ),
                last_activity_at: CorePatch::from(was.last_activity_at.as_deref(), data.last_activity_at.as_deref()),
                ..Default::default()
            };
            if !fields.is_empty() {
                operations.push(CoreFolderOperation::PatchTab { id: change.entity_id.clone(), fields });
            }
            if data.placement == CoreTabPlacement::SpacePinned {
                let home = home_patch(data, was);
                if !home.is_unchanged() {
                    home_patches.push(CoreFolderOperation::PatchTab {
                        id: change.entity_id.clone(),
                        fields: CoreSyncTabPatch { pinned_url_string: home, ..Default::default() },
                    });
                }
            }
        }
    }
    for plan in &plans {
        let anchors: HashSet<Ref> = plan.kept.union(&plan.created).cloned().collect();
        let following = following_anchors(&plan.items, &anchors);
        let mut index = 0;
        while index < plan.items.len() {
            if anchors.contains(&plan.items[index]) {
                index += 1;
                continue;
            }
            let start = index;
            let Some(first) = next.get(&plan.items[index].key()) else {
                index += 1;
                continue;
            };
            let target = destination(first);
            while index < plan.items.len()
                && !anchors.contains(&plan.items[index])
                && index - start < 1000
                && next.get(&plan.items[index].key()).is_some_and(|item| same_destination(&destination(item), &target))
            {
                index += 1;
            }
            operations.push(CoreFolderOperation::Move {
                items: plan.items[start..index].to_vec(),
                destination: target,
                before: following[index - 1].cloned(),
                after: (start > 0).then(|| plan.items[start - 1].clone()),
            });
        }
    }
    operations.extend(home_patches);
    let removed: HashSet<Ref> =
        before.iter().filter(|change| !next.contains_key(&key_of(change))).map(Ref::of).collect();
    let removed_folder_above = |parent: Option<&str>| {
        ancestors(parent, &old).iter().any(|id| removed.contains(&Ref::new(CoreSyncEntityType::Folder, id)))
    };
    for change in before.iter().filter(|change| removed.contains(&Ref::of(change))) {
        if let Some(data) = &change.folder_data {
            if removed.contains(&Ref::new(CoreSyncEntityType::Space, &data.space_id))
                || removed_folder_above(data.parent_folder_id.as_deref())
            {
                continue;
            }
            operations.push(CoreFolderOperation::DeleteFolder { id: change.entity_id.clone() });
        } else if let Some(data) = &change.tab_data {
            if data.placement != CoreTabPlacement::App
                && (removed.contains(&Ref::new(CoreSyncEntityType::Space, &data.space_id))
                    || removed_folder_above(data.pinned_folder_id.as_deref()))
            {
                continue;
            }
            operations.push(CoreFolderOperation::DeleteTab { id: change.entity_id.clone() });
        }
    }
    for change in &before {
        if change.entity_type == CoreSyncEntityType::Space && removed.contains(&Ref::of(change)) {
            operations.push(CoreFolderOperation::DeleteSpace { id: change.entity_id.clone() });
        }
    }
    operations
}

fn parent_of(change: &CoreSyncChange) -> Option<&str> {
    change
        .folder_data
        .as_ref()
        .and_then(|data| data.parent_folder_id.as_deref())
        .or_else(|| change.tab_data.as_ref().and_then(|data| data.pinned_folder_id.as_deref()))
}

fn first_by_key(changes: &[CoreSyncChange]) -> HashMap<String, &CoreSyncChange> {
    let mut result = HashMap::new();
    for change in changes {
        result.entry(key_of(change)).or_insert(change);
    }
    result
}

/// Applies operations to canonical values as the server does, skipping what it would reject.
pub fn apply(operations: &[CoreFolderOperation], values: &mut Values, deleted: &mut HashSet<String>) {
    for operation in operations {
        match operation {
            CoreFolderOperation::CreateSpace { id, data, before, after } => {
                let change = CoreSyncChange::space(
                    id,
                    CoreSyncSpacePayload {
                        title: data.title.clone(),
                        system_image_name: data.system_image_name.clone(),
                        rank: 0.0,
                        is_pinned_section_collapsed: data.is_pinned_section_collapsed,
                        selected_tab_id: data.selected_tab_id.clone(),
                    },
                );
                create(change, before.as_ref(), after.as_ref(), values, deleted);
            }
            CoreFolderOperation::CreateFolder { id, data, before, after } => {
                let change = CoreSyncChange::folder(
                    id,
                    CoreSyncFolderPayload {
                        space_id: data.space_id.clone(),
                        parent_folder_id: data.parent_folder_id.clone(),
                        title: data.title.clone(),
                        system_image_name: data.system_image_name.clone(),
                        rank: 0.0,
                    },
                );
                create(change, before.as_ref(), after.as_ref(), values, deleted);
            }
            CoreFolderOperation::CreateTab { id, data: creation, before, after } => {
                let data = &creation.base;
                let change = CoreSyncChange::tab(
                    id,
                    CoreSyncTabPayload {
                        space_id: data.space_id.clone(),
                        placement: data.placement,
                        rank: 0.0,
                        url_string: data.url_string.clone(),
                        pinned_url_string: (data.placement == CoreTabPlacement::SpacePinned)
                            .then(|| data.pinned_url_string.clone().unwrap_or_else(|| data.url_string.clone())),
                        title: data.title.clone(),
                        user_title_override: data.user_title_override.clone(),
                        favicon_url_string: data.favicon_url_string.clone(),
                        last_activity_at: data.last_activity_at.clone(),
                        pinned_folder_id: creation.pinned_folder_id.clone(),
                    },
                );
                create(change, before.as_ref(), after.as_ref(), values, deleted);
            }
            CoreFolderOperation::PatchSpace { id, fields } => {
                let Some(old) = live(&Ref::new(CoreSyncEntityType::Space, id), values, deleted) else { continue };
                let Some(data) = &old.space_data else { continue };
                let change = CoreSyncChange::space(
                    id,
                    CoreSyncSpacePayload {
                        title: fields.title.clone().unwrap_or_else(|| data.title.clone()),
                        system_image_name: fields
                            .system_image_name
                            .clone()
                            .unwrap_or_else(|| data.system_image_name.clone()),
                        rank: data.rank,
                        is_pinned_section_collapsed: fields
                            .is_pinned_section_collapsed
                            .unwrap_or(data.is_pinned_section_collapsed),
                        selected_tab_id: fields.selected_tab_id.applied(data.selected_tab_id.as_deref()),
                    },
                );
                values.insert(key_of(old), change);
            }
            CoreFolderOperation::PatchFolder { id, fields } => {
                let Some(old) = live(&Ref::new(CoreSyncEntityType::Folder, id), values, deleted) else { continue };
                let Some(data) = &old.folder_data else { continue };
                let folder = CoreSyncFolderPayload {
                    space_id: data.space_id.clone(),
                    parent_folder_id: data.parent_folder_id.clone(),
                    title: fields.title.clone().unwrap_or_else(|| data.title.clone()),
                    system_image_name: fields.system_image_name.applied(data.system_image_name.as_deref()),
                    rank: data.rank,
                };
                let change = replacing_folder(old, folder);
                values.insert(key_of(&change), change);
            }
            CoreFolderOperation::PatchTab { id, fields } => {
                let Some(old) = live(&Ref::new(CoreSyncEntityType::Tab, id), values, deleted) else { continue };
                let Some(data) = &old.tab_data else { continue };
                let activity = fields.last_activity_at.applied(data.last_activity_at.as_deref());
                let tab = CoreSyncTabPayload {
                    space_id: data.space_id.clone(),
                    placement: data.placement,
                    rank: data.rank,
                    url_string: fields.url_string.clone().unwrap_or_else(|| data.url_string.clone()),
                    pinned_url_string: if data.placement == CoreTabPlacement::SpacePinned {
                        fields.pinned_url_string.applied(data.pinned_url_string.as_deref())
                    } else {
                        None
                    },
                    title: fields.title.applied(data.title.as_deref()),
                    user_title_override: fields.user_title_override.applied(data.user_title_override.as_deref()),
                    favicon_url_string: fields.favicon_url_string.applied(data.favicon_url_string.as_deref()),
                    last_activity_at: dates::latest(data.last_activity_at.as_deref(), activity.as_deref())
                        .map(str::to_owned),
                    pinned_folder_id: data.pinned_folder_id.clone(),
                };
                let change = replacing_tab(old, tab);
                values.insert(key_of(&change), change);
            }
            CoreFolderOperation::Move { items, destination, before, after } => {
                move_entities(items, destination, before.as_ref(), after.as_ref(), values, deleted);
            }
            CoreFolderOperation::DeleteSpace { id } => {
                remove(&Ref::new(CoreSyncEntityType::Space, id), values, deleted)
            }
            CoreFolderOperation::DeleteTab { id } => remove(&Ref::new(CoreSyncEntityType::Tab, id), values, deleted),
            CoreFolderOperation::DeleteFolder { id } => {
                remove(&Ref::new(CoreSyncEntityType::Folder, id), values, deleted)
            }
        }
    }
}

/// The session the app shows for the live canonical entities, keeping this device's titles, icons,
/// colors and folder expansion from `local`.
pub fn snapshot(values: &Values, local: Option<&CoreSessionSnapshot>) -> CoreSessionSnapshot {
    let ordered = ordered_values(values);
    let old_tabs = first_by_id(local.map(|local| local.tabs.as_slice()).unwrap_or_default());
    let mut old_folders: HashMap<&str, &CoreFolderSnapshot> = HashMap::new();
    for folder in local.and_then(|local| local.pinned_tab_folders.as_deref()).unwrap_or_default() {
        old_folders.entry(folder.id.as_str()).or_insert(folder);
    }
    let tabs: Vec<CoreTabSnapshot> = ordered
        .iter()
        .filter_map(|change| {
            let data = change.tab_data.as_ref()?;
            let previous = old_tabs.get(change.entity_id.as_str());
            Some(CoreTabSnapshot {
                id: Some(change.entity_id.clone()),
                url_string: data.url_string.clone(),
                pinned_url_string: data.pinned_url_string.clone(),
                user_title_override: data.user_title_override.clone(),
                placement: data.placement,
                space_id: Some(data.space_id.clone()),
                pinned_folder_id: data.pinned_folder_id.clone(),
                pinned_sibling_rank: (data.placement == CoreTabPlacement::SpacePinned).then_some(data.rank),
                last_activity_timestamp: dates::projected_timestamp(
                    data.last_activity_at.as_deref(),
                    previous.and_then(|previous| previous.last_activity_timestamp),
                ),
                // Titles and icons are local; keep this device's.
                page_title: previous.and_then(|previous| previous.page_title.clone()),
                system_image_name: previous.and_then(|previous| previous.system_image_name.clone()),
            })
        })
        .collect();
    let folders: Vec<CoreFolderSnapshot> = ordered
        .iter()
        .filter_map(|change| {
            let data = change.folder_data.as_ref()?;
            Some(CoreFolderSnapshot {
                id: change.entity_id.clone(),
                space_id: data.space_id.clone(),
                parent_folder_id: data.parent_folder_id.clone(),
                title: data.title.clone(),
                system_image_name: data.system_image_name.clone(),
                is_expanded: old_folders.get(change.entity_id.as_str()).is_none_or(|folder| folder.is_expanded),
                pinned_sibling_rank: Some(data.rank),
            })
        })
        .collect();
    let spaces: Vec<CoreSpaceSnapshot> = ordered
        .iter()
        .filter_map(|change| change.space_data.as_ref().map(|data| space_snapshot(change, data, local, &tabs)))
        .collect();
    CoreSessionSnapshot {
        spaces: if spaces.is_empty() { None } else { Some(spaces) },
        pinned_tab_folders: if folders.is_empty() { None } else { Some(folders) },
        tabs,
    }
}

/// The operations that bring this device's local folders and pinned-tab memberships into canonical
/// state that has none of them. Canonical folders and existing memberships keep authority.
pub fn adoption_operations(
    local: &CoreSessionSnapshot,
    values: &Values,
    deleted: &HashSet<String>,
    default_space_title: &str,
) -> Vec<CoreFolderOperation> {
    let mut current: Values = values
        .iter()
        .filter(|(key, value)| value.op == CoreSyncOp::Upsert && !deleted.contains(*key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let mut tombstones = deleted.clone();
    let local_changes = canonical_changes(local, default_space_title);
    let mut groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    let mut containers = Vec::new();
    for change in &local_changes {
        let list = Container::of(change);
        if !groups.contains_key(&list) {
            containers.push(list.clone());
        }
        groups.entry(list).or_default().push(change);
    }
    let mut result = Vec::new();
    let mut append = |operation: CoreFolderOperation, current: &mut Values, tombstones: &mut HashSet<String>| {
        apply(std::slice::from_ref(&operation), current, tombstones);
        result.push(operation);
    };
    let in_list = |reference: &Ref, list: &Container, current: &Values, tombstones: &HashSet<String>| {
        live(reference, current, tombstones).is_some_and(|change| Container::of(change) == *list)
    };
    // Legacy tab ranks describe one flat list and cannot be compared with local mixed sibling ranks.
    // Adopt through typed neighbors instead.
    for list in &containers {
        let siblings = &groups[list];
        let references: Vec<Ref> = siblings.iter().map(|change| Ref::of(change)).collect();
        let anchors: HashSet<Ref> =
            references.iter().filter(|reference| in_list(reference, list, &current, &tombstones)).cloned().collect();
        let following = following_anchors(&references, &anchors);
        let mut preceding: Option<Ref> = None;
        for (index, change) in siblings.iter().enumerate() {
            let change_key = key_of(change);
            if change.folder_data.is_some()
                && !current.contains_key(&change_key)
                && !tombstones.contains(&change_key)
                && valid(&destination(change), &current, &tombstones)
            {
                let operation = create_operation(change, following[index].cloned(), preceding.clone());
                append(operation, &mut current, &mut tombstones);
            }
            if in_list(&references[index], list, &current, &tombstones) {
                preceding = Some(references[index].clone());
            }
        }
    }
    let adopted: HashSet<Ref> = local_changes
        .iter()
        .filter_map(|change| {
            let local_tab = change.tab_data.as_ref()?;
            if local_tab.placement != CoreTabPlacement::SpacePinned {
                return None;
            }
            let parent = local_tab.pinned_folder_id.as_deref()?;
            let tab = live(&Ref::of(change), &current, &tombstones)?.tab_data.as_ref()?;
            if tab.placement != CoreTabPlacement::SpacePinned || tab.pinned_folder_id.is_some() {
                return None;
            }
            let folder =
                live(&Ref::new(CoreSyncEntityType::Folder, parent), &current, &tombstones)?.folder_data.as_ref()?;
            same(&folder.space_id, &tab.space_id).then(|| Ref::of(change))
        })
        .collect();
    for list in &containers {
        let siblings = &groups[list];
        let references: Vec<Ref> = siblings.iter().map(|change| Ref::of(change)).collect();
        let anchors: HashSet<Ref> = references
            .iter()
            .filter(|reference| !adopted.contains(*reference) && in_list(reference, list, &current, &tombstones))
            .cloned()
            .collect();
        let following = following_anchors(&references, &anchors);
        let mut preceding: Option<Ref> = None;
        let mut index = 0;
        while index < siblings.len() {
            if !adopted.contains(&references[index]) {
                if anchors.contains(&references[index]) {
                    preceding = Some(references[index].clone());
                }
                index += 1;
                continue;
            }
            let start = index;
            while index < siblings.len() && adopted.contains(&references[index]) && index - start < 1000 {
                index += 1;
            }
            let operation = CoreFolderOperation::Move {
                items: references[start..index].to_vec(),
                destination: destination(siblings[start]),
                before: following[index - 1].cloned(),
                after: preceding.clone(),
            };
            append(operation, &mut current, &mut tombstones);
            preceding = Some(references[index - 1].clone());
        }
    }
    result
}

fn live<'a>(reference: &Ref, values: &'a Values, deleted: &HashSet<String>) -> Option<&'a CoreSyncChange> {
    let key = reference.key();
    if deleted.contains(&key) {
        return None;
    }
    values.get(&key).filter(|value| value.op == CoreSyncOp::Upsert)
}

fn valid(destination: &CoreSyncFolderDestination, values: &Values, deleted: &HashSet<String>) -> bool {
    let CoreSyncFolderDestination::Tabs { space_id, placement, pinned_folder_id } = destination else { return true };
    if *placement != CoreTabPlacement::SpacePinned && pinned_folder_id.is_some() {
        return false;
    }
    if *placement == CoreTabPlacement::App {
        return true;
    }
    if live(&Ref::new(CoreSyncEntityType::Space, space_id), values, deleted)
        .is_none_or(|space| space.space_data.is_none())
    {
        return false;
    }
    let mut current = pinned_folder_id.as_deref();
    let mut seen = HashSet::new();
    while let Some(id) = current {
        if !seen.insert(id) {
            return false;
        }
        let Some(parent) = live(&Ref::new(CoreSyncEntityType::Folder, id), values, deleted)
            .and_then(|change| change.folder_data.as_ref())
        else {
            return false;
        };
        if !same(&parent.space_id, space_id) {
            return false;
        }
        current = parent.parent_folder_id.as_deref();
    }
    true
}

fn list(container: &Container, values: &Values, deleted: &HashSet<String>) -> Vec<CoreSyncChange> {
    let mut result: Vec<&CoreSyncChange> = values
        .values()
        .filter(|change| {
            change.op == CoreSyncOp::Upsert && !deleted.contains(&key_of(change)) && Container::of(change) == *container
        })
        .collect();
    result.sort_by(|left, right| by_rank_then_key(left, right));
    result.into_iter().cloned().collect()
}

fn ordered_values(values: &Values) -> Vec<CoreSyncChange> {
    let none = HashSet::new();
    let spaces = list(&Container::Spaces, values, &none);
    let mut groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    for change in values.values().filter(|change| change.op == CoreSyncOp::Upsert) {
        groups.entry(Container::of(change)).or_default().push(change);
    }
    for group in groups.values_mut() {
        group.sort_by(|left, right| by_rank_then_key(left, right));
    }
    let mut output = spaces.clone();
    output.extend(list(&Container::Apps, values, &none));
    let mut seen = HashSet::new();
    fn append_pinned(
        space: &str,
        parent: Option<&str>,
        groups: &HashMap<Container, Vec<&CoreSyncChange>>,
        seen: &mut HashSet<Ref>,
        output: &mut Vec<CoreSyncChange>,
    ) {
        let Some(items) = groups.get(&Container::Pinned(space.to_owned(), parent.map(str::to_owned))) else { return };
        for item in items {
            if !seen.insert(Ref::of(item)) {
                continue;
            }
            output.push((*item).clone());
            if item.folder_data.is_some() {
                append_pinned(space, Some(&item.entity_id), groups, seen, output);
            }
        }
    }
    for space in &spaces {
        append_pinned(&space.entity_id, None, &groups, &mut seen, &mut output);
        output.extend(list(&Container::Temporary(space.entity_id.clone()), values, &none));
    }
    output
}

fn ancestors(id: Option<&str>, values: &HashMap<String, &CoreSyncChange>) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = id.map(str::to_owned);
    let mut seen = HashSet::new();
    while let Some(parent) = current {
        if !seen.insert(parent.clone()) {
            break;
        }
        current = values
            .get(&key(CoreSyncEntityType::Folder, &parent))
            .and_then(|change| change.folder_data.as_ref())
            .and_then(|data| data.parent_folder_id.clone());
        result.push(parent);
    }
    result
}

fn subtree(roots: HashSet<String>, values: &Values, deleted: &HashSet<String>) -> HashSet<String> {
    let mut children: HashMap<Option<&str>, Vec<&str>> = HashMap::new();
    for change in values.values() {
        if let Some(data) = &change.folder_data
            && change.op == CoreSyncOp::Upsert
            && !deleted.contains(&key_of(change))
        {
            children.entry(data.parent_folder_id.as_deref()).or_default().push(&change.entity_id);
        }
    }
    let mut queue: Vec<String> = roots.iter().cloned().collect();
    let mut result = roots;
    let mut index = 0;
    while index < queue.len() {
        let parent = queue[index].clone();
        for &child in children.get(&Some(parent.as_str())).into_iter().flatten() {
            if result.insert(child.to_owned()) {
                queue.push(child.to_owned());
            }
        }
        index += 1;
    }
    result
}

fn move_context(
    items: &[Ref],
    destination: &CoreSyncFolderDestination,
    values: &Values,
    deleted: &HashSet<String>,
) -> Option<(Vec<CoreSyncChange>, HashSet<String>)> {
    if !valid(destination, values, deleted) || items.iter().collect::<HashSet<_>>().len() != items.len() {
        return None;
    }
    let survivors: Vec<CoreSyncChange> = items.iter().filter_map(|item| live(item, values, deleted).cloned()).collect();
    let allowed = |change: &CoreSyncChange| match destination {
        CoreSyncFolderDestination::Spaces => change.entity_type == CoreSyncEntityType::Space,
        CoreSyncFolderDestination::Tabs { placement, .. } => {
            change.entity_type != CoreSyncEntityType::Space
                && (change.entity_type != CoreSyncEntityType::Folder || *placement == CoreTabPlacement::SpacePinned)
        }
    };
    if survivors.is_empty() || !survivors.iter().all(allowed) {
        return None;
    }
    let roots =
        survivors.iter().filter(|change| change.folder_data.is_some()).map(|change| change.entity_id.clone()).collect();
    let folders = subtree(roots, values, deleted);
    if survivors.iter().any(|change| parent_of(change).is_some_and(|parent| folders.contains(parent))) {
        return None;
    }
    if let CoreSyncFolderDestination::Tabs { pinned_folder_id: Some(parent), .. } = destination
        && folders.contains(parent)
    {
        return None;
    }
    Some((survivors, folders))
}

fn move_entities(
    items: &[Ref],
    target: &CoreSyncFolderDestination,
    before: Option<&Ref>,
    after: Option<&Ref>,
    values: &mut Values,
    deleted: &HashSet<String>,
) {
    let Some((survivors, folders)) = move_context(items, target, values, deleted) else { return };
    let moved: HashSet<Ref> = survivors.iter().map(Ref::of).collect();
    let target_list = Container::of_destination(target);
    let sources: HashSet<Container> = survivors.iter().map(Container::of).collect();
    for source in sources {
        if source != target_list {
            let remaining =
                list(&source, values, deleted).into_iter().filter(|change| !moved.contains(&Ref::of(change))).collect();
            publish(remaining, values);
        }
    }
    let group = survivors.iter().map(|change| relocated(change, target)).collect();
    if let CoreSyncFolderDestination::Tabs { space_id, .. } = target {
        let updates: Vec<CoreSyncChange> = values
            .values()
            .filter(|change| !moved.contains(&Ref::of(change)) && change.op == CoreSyncOp::Upsert)
            .filter_map(|change| {
                if let Some(folder) = &change.folder_data
                    && folders.contains(&change.entity_id)
                {
                    let mut folder = folder.clone();
                    folder.space_id = space_id.clone();
                    Some(replacing_folder(change, folder))
                } else if let Some(tab) = &change.tab_data
                    && tab.placement == CoreTabPlacement::SpacePinned
                    && tab.pinned_folder_id.as_ref().is_some_and(|folder| folders.contains(folder))
                {
                    Some(relocated(
                        change,
                        &CoreSyncFolderDestination::Tabs {
                            space_id: space_id.clone(),
                            placement: CoreTabPlacement::SpacePinned,
                            pinned_folder_id: tab.pinned_folder_id.clone(),
                        },
                    ))
                } else {
                    None
                }
            })
            .collect();
        for change in updates {
            values.insert(key_of(&change), change);
        }
    }
    insert(group, &target_list, before, after, values, deleted);
}

fn create(
    change: CoreSyncChange,
    before: Option<&Ref>,
    after: Option<&Ref>,
    values: &mut Values,
    deleted: &HashSet<String>,
) {
    if deleted.contains(&key_of(&change))
        || live(&Ref::of(&change), values, deleted).is_some()
        || !valid(&destination(&change), values, deleted)
    {
        return;
    }
    let list = Container::of(&change);
    insert(vec![change], &list, before, after, values, deleted);
}

fn insert(
    group: Vec<CoreSyncChange>,
    target: &Container,
    before: Option<&Ref>,
    after: Option<&Ref>,
    values: &mut Values,
    deleted: &HashSet<String>,
) {
    let moving: HashSet<Ref> = group.iter().map(Ref::of).collect();
    let mut siblings: Vec<CoreSyncChange> =
        list(target, values, deleted).into_iter().filter(|change| !moving.contains(&Ref::of(change))).collect();
    let before_index = before.and_then(|anchor| siblings.iter().position(|change| Ref::of(change) == *anchor));
    let after_index =
        after.and_then(|anchor| siblings.iter().position(|change| Ref::of(change) == *anchor).map(|index| index + 1));
    let at = before_index.or(after_index).unwrap_or(siblings.len());
    siblings.splice(at..at, group);
    publish(siblings, values);
}

fn publish(items: Vec<CoreSyncChange>, values: &mut Values) {
    for (index, item) in items.iter().enumerate() {
        values.insert(key_of(item), ranked(item, index as f64));
    }
}

fn remove(reference: &Ref, values: &mut Values, deleted: &mut HashSet<String>) {
    let old = values.get(&reference.key()).cloned();
    let folders = if reference.entity_type == CoreSyncEntityType::Folder {
        subtree(HashSet::from([reference.entity_id.clone()]), values, deleted)
    } else {
        HashSet::new()
    };
    let mut targets = vec![reference.clone()];
    for value in values.values().filter(|value| value.op == CoreSyncOp::Upsert) {
        let hit = match reference.entity_type {
            CoreSyncEntityType::Space => {
                value.folder_data.as_ref().is_some_and(|folder| same(&folder.space_id, &reference.entity_id))
                    || value.tab_data.as_ref().is_some_and(|tab| {
                        same(&tab.space_id, &reference.entity_id) && tab.placement != CoreTabPlacement::App
                    })
            }
            CoreSyncEntityType::Folder => {
                (value.entity_type == CoreSyncEntityType::Folder && folders.contains(&value.entity_id))
                    || value.tab_data.as_ref().is_some_and(|tab| {
                        tab.placement == CoreTabPlacement::SpacePinned
                            && tab.pinned_folder_id.as_ref().is_some_and(|folder| folders.contains(folder))
                    })
            }
            CoreSyncEntityType::Tab => false,
        };
        if hit {
            targets.push(Ref::of(value));
        }
    }
    for target in targets {
        deleted.insert(target.key());
        values.insert(target.key(), CoreSyncChange::deleted(target.entity_type, &target.entity_id));
    }
    if let Some(old) = old {
        let container = Container::of(&old);
        publish(list(&container, values, deleted), values);
    }
}

fn ranked(change: &CoreSyncChange, rank: f64) -> CoreSyncChange {
    if let Some(data) = &change.space_data {
        let mut data = data.clone();
        data.rank = rank;
        let mut result = CoreSyncChange::space(&change.entity_id, data);
        result.op = change.op;
        return result;
    }
    if let Some(data) = &change.folder_data {
        let mut data = data.clone();
        data.rank = rank;
        return replacing_folder(change, data);
    }
    let Some(data) = &change.tab_data else { return change.clone() };
    let mut data = data.clone();
    data.rank = rank;
    replacing_tab(change, data)
}

fn relocated(change: &CoreSyncChange, target: &CoreSyncFolderDestination) -> CoreSyncChange {
    let CoreSyncFolderDestination::Tabs { space_id, placement, pinned_folder_id } = target else {
        return change.clone();
    };
    if let Some(folder) = &change.folder_data {
        let mut folder = folder.clone();
        folder.space_id = space_id.clone();
        folder.parent_folder_id = pinned_folder_id.clone();
        return replacing_folder(change, folder);
    }
    let Some(tab) = &change.tab_data else { return change.clone() };
    let home = if *placement == CoreTabPlacement::SpacePinned {
        if tab.placement == CoreTabPlacement::SpacePinned {
            tab.pinned_url_string.clone()
        } else {
            Some(tab.url_string.clone())
        }
    } else {
        None
    };
    let mut tab = tab.clone();
    tab.space_id = space_id.clone();
    tab.placement = *placement;
    tab.pinned_url_string = home;
    tab.pinned_folder_id = pinned_folder_id.clone();
    replacing_tab(change, tab)
}

fn replacing_tab(old: &CoreSyncChange, tab: CoreSyncTabPayload) -> CoreSyncChange {
    let mut result = CoreSyncChange::tab(&old.entity_id, tab);
    result.op = old.op;
    result
}

fn replacing_folder(old: &CoreSyncChange, folder: CoreSyncFolderPayload) -> CoreSyncChange {
    let mut result = CoreSyncChange::folder(&old.entity_id, folder);
    result.op = old.op;
    result
}

fn create_operation(change: &CoreSyncChange, before: Option<Ref>, after: Option<Ref>) -> CoreFolderOperation {
    if let Some(data) = &change.space_data {
        return CoreFolderOperation::CreateSpace {
            id: change.entity_id.clone(),
            data: CoreSyncSpaceCreate {
                title: data.title.clone(),
                system_image_name: data.system_image_name.clone(),
                is_pinned_section_collapsed: data.is_pinned_section_collapsed,
                selected_tab_id: data.selected_tab_id.clone(),
            },
            before,
            after,
        };
    }
    if let Some(data) = &change.folder_data {
        return CoreFolderOperation::CreateFolder {
            id: change.entity_id.clone(),
            data: CoreSyncFolderCreate {
                space_id: data.space_id.clone(),
                parent_folder_id: data.parent_folder_id.clone(),
                title: data.title.clone(),
                system_image_name: data.system_image_name.clone(),
            },
            before,
            after,
        };
    }
    let data = change.tab_data.as_ref().expect("a canonical change holds a Space, a folder or a tab");
    CoreFolderOperation::CreateTab {
        id: change.entity_id.clone(),
        data: CoreSyncFolderTabCreate {
            base: CoreSyncTabCreate {
                space_id: data.space_id.clone(),
                placement: data.placement,
                url_string: data.url_string.clone(),
                pinned_url_string: data.pinned_url_string.clone(),
                title: data.title.clone(),
                user_title_override: data.user_title_override.clone(),
                favicon_url_string: data.favicon_url_string.clone(),
                last_activity_at: data.last_activity_at.clone(),
            },
            pinned_folder_id: data.pinned_folder_id.clone(),
        },
        before,
        after,
    }
}
