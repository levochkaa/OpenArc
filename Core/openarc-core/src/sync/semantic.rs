//! Protocol version 3: operations between two sessions, and their replay over canonical values.
//!
//! Direct moves keep the identities the user moved. Without a move intent, a minimal move set follows
//! from relative order.

use std::collections::{HashMap, HashSet};

use super::dates;
use super::model::*;
use super::outbox::{canonical_changes, replacing_rank};
use super::text::{order, same};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Container {
    Spaces,
    Apps,
    Tabs { space_id: String, pinned: bool },
}

impl Container {
    fn tab(space_id: &str, placement: CoreTabPlacement) -> Self {
        if placement == CoreTabPlacement::App {
            Self::Apps
        } else {
            Self::Tabs { space_id: space_id.to_owned(), pinned: placement == CoreTabPlacement::SpacePinned }
        }
    }

    fn of(change: &CoreSyncChange) -> Self {
        change.tab_data.as_ref().map_or(Self::Spaces, |data| Self::tab(&data.space_id, data.placement))
    }

    fn key(&self, id: &str) -> String {
        key(if *self == Self::Spaces { CoreSyncEntityType::Space } else { CoreSyncEntityType::Tab }, id)
    }

    /// `Container::of(change) == *self` without building the container: replay lists a container once per
    /// queued move, over every entity.
    fn holds(&self, change: &CoreSyncChange) -> bool {
        let Some(data) = &change.tab_data else { return *self == Self::Spaces };
        match self {
            Self::Spaces => false,
            Self::Apps => data.placement == CoreTabPlacement::App,
            Self::Tabs { space_id, pinned } => {
                data.placement != CoreTabPlacement::App
                    && (data.placement == CoreTabPlacement::SpacePinned) == *pinned
                    && data.space_id == *space_id
            }
        }
    }
}

struct OrderPlan {
    container: Container,
    ids: Vec<String>,
    kept: HashSet<String>,
    created: HashSet<String>,
}

/// The operations that turn `previous` into `snapshot`. `move_tab_ids` names the tabs a direct move acted
/// on, in their final order; pass an empty list when the sessions are equal.
pub fn operations(
    previous: Option<&CoreSessionSnapshot>,
    snapshot: &CoreSessionSnapshot,
    move_tab_ids: Option<&[String]>,
    default_space_title: &str,
) -> Vec<CoreSemanticOperation> {
    let before = canonical_changes(previous.unwrap_or(&CoreSessionSnapshot::default()), default_space_title);
    let after = canonical_changes(snapshot, default_space_title);
    let previous_by_key: HashMap<String, &CoreSyncChange> =
        before.iter().map(|change| (key_of(change), change)).collect();
    let next_by_key: HashMap<String, &CoreSyncChange> = after.iter().map(|change| (key_of(change), change)).collect();
    // The store rejects duplicate IDs. Deduplicate for pure callers too, so no generated move can break the
    // wire's unique-ID rule.
    let explicit_order: Option<Vec<String>> = move_tab_ids.map(|ids| {
        let mut seen = HashSet::new();
        ids.iter().filter(|id| seen.insert(id.as_str())).cloned().collect()
    });
    let plans =
        order_plans(&before, &after, explicit_order.as_ref().map(|ids| ids.iter().map(String::as_str).collect()));
    let mut result = Vec::new();
    let mut home_patches = Vec::new();

    // Parents precede child creates. New entities anchor to unchanged survivors, not to an old neighbor
    // that a later operation moves away.
    for plan in &plans {
        let mut previous_anchor: Option<&String> = None;
        let next_kept = following_anchors(&plan.ids, &plan.kept);
        for (index, id) in plan.ids.iter().enumerate() {
            if plan.created.contains(id)
                && let Some(change) = next_by_key.get(&plan.container.key(id))
            {
                let before_id = next_kept[index].cloned();
                let after_id = previous_anchor.cloned();
                if let Some(data) = &change.space_data {
                    result.push(CoreSemanticOperation::CreateSpace {
                        id: id.clone(),
                        data: CoreSyncSpaceCreate {
                            title: data.title.clone(),
                            system_image_name: data.system_image_name.clone(),
                            is_pinned_section_collapsed: data.is_pinned_section_collapsed,
                            selected_tab_id: data.selected_tab_id.clone(),
                        },
                        before_id,
                        after_id,
                    });
                } else if let Some(data) = &change.tab_data {
                    result.push(CoreSemanticOperation::CreateTab {
                        id: id.clone(),
                        data: CoreSyncTabCreate {
                            space_id: data.space_id.clone(),
                            placement: data.placement,
                            url_string: data.url_string.clone(),
                            pinned_url_string: data.pinned_url_string.clone(),
                            title: data.title.clone(),
                            user_title_override: data.user_title_override.clone(),
                            favicon_url_string: data.favicon_url_string.clone(),
                            last_activity_at: data.last_activity_at.clone(),
                        },
                        before_id,
                        after_id,
                    });
                }
            }
            if plan.kept.contains(id) || plan.created.contains(id) {
                previous_anchor = Some(id);
            }
        }
    }

    for change in &after {
        let Some(old) = previous_by_key.get(&key_of(change)) else { continue };
        if let (Some(data), Some(was)) = (&change.space_data, &old.space_data) {
            let fields =
                space_patch(data.title.as_str(), &data.system_image_name, data.is_pinned_section_collapsed, was);
            if !fields.is_empty() {
                result.push(CoreSemanticOperation::PatchSpace { id: change.entity_id.clone(), fields });
            }
        } else if let (Some(data), Some(was)) = (&change.tab_data, &old.tab_data) {
            // Page titles and favicons are not in the session. Never clear metadata it does not own.
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
                result.push(CoreSemanticOperation::PatchTab { id: change.entity_id.clone(), fields });
            }
            if data.placement == CoreTabPlacement::SpacePinned {
                let home = home_patch(data, was);
                if !home.is_unchanged() {
                    home_patches.push(CoreSemanticOperation::PatchTab {
                        id: change.entity_id.clone(),
                        fields: CoreSyncTabPatch { pinned_url_string: home, ..Default::default() },
                    });
                }
            }
        }
    }

    for plan in &plans {
        if let Some(explicit_order) = &explicit_order
            && plan.container != Container::Spaces
        {
            result.extend(explicit_tab_moves(plan, explicit_order, &next_by_key));
            continue;
        }
        let anchors: HashSet<String> = plan.kept.union(&plan.created).cloned().collect();
        let next_anchors = following_anchors(&plan.ids, &anchors);
        let mut index = 0;
        while index < plan.ids.len() {
            if anchors.contains(&plan.ids[index]) {
                index += 1;
                continue;
            }
            let start = index;
            while index < plan.ids.len() && !anchors.contains(&plan.ids[index]) && index - start < 1000 {
                index += 1;
            }
            let ids = plan.ids[start..index].to_vec();
            let before_id = next_anchors[index - 1].cloned();
            let after_id = (start > 0).then(|| plan.ids[start - 1].clone());
            match &plan.container {
                Container::Spaces => result.push(CoreSemanticOperation::MoveSpaces { ids, before_id, after_id }),
                Container::Apps | Container::Tabs { .. } => {
                    let Some(data) =
                        next_by_key.get(&plan.container.key(&ids[0])).and_then(|change| change.tab_data.as_ref())
                    else {
                        continue;
                    };
                    result.push(CoreSemanticOperation::MoveTabs {
                        ids,
                        destination: CoreSyncTabDestination {
                            space_id: data.space_id.clone(),
                            placement: data.placement,
                        },
                        before_id,
                        after_id,
                    });
                }
            }
        }
    }
    result.extend(home_patches);
    // Move-outs reach the server before the delete of their former parent.
    let removed_spaces: HashSet<&str> = before
        .iter()
        .filter(|change| change.entity_type == CoreSyncEntityType::Space && !next_by_key.contains_key(&key_of(change)))
        .map(|change| change.entity_id.as_str())
        .collect();
    for change in &before {
        if next_by_key.contains_key(&key_of(change)) || change.entity_type != CoreSyncEntityType::Tab {
            continue;
        }
        // Delete only current canonical children. A stale child delete would destroy tabs another
        // device moved away.
        if let Some(data) = &change.tab_data
            && data.placement != CoreTabPlacement::App
            && removed_spaces.contains(data.space_id.as_str())
        {
            continue;
        }
        result.push(CoreSemanticOperation::DeleteTab { id: change.entity_id.clone() });
    }
    for change in &before {
        if !next_by_key.contains_key(&key_of(change)) && change.entity_type == CoreSyncEntityType::Space {
            result.push(CoreSemanticOperation::DeleteSpace { id: change.entity_id.clone() });
        }
    }
    result
}

/// The Space fields that differ from `was`.
pub fn space_patch(title: &str, icon: &str, collapsed: bool, was: &CoreSyncSpacePayload) -> CoreSyncSpacePatch {
    CoreSyncSpacePatch {
        title: (!same(title, &was.title)).then(|| title.to_owned()),
        system_image_name: (!same(icon, &was.system_image_name)).then(|| icon.to_owned()),
        is_pinned_section_collapsed: (collapsed != was.is_pinned_section_collapsed).then_some(collapsed),
        selected_tab_id: CorePatch::Unchanged,
    }
}

/// A pinned tab's home page patch. A newly pinned tab takes its current canonical address at move time,
/// so a concurrent navigation is never overwritten with the stale local address.
pub fn home_patch(data: &CoreSyncTabPayload, was: &CoreSyncTabPayload) -> CorePatch {
    if was.placement == CoreTabPlacement::SpacePinned {
        CorePatch::from(was.pinned_url_string.as_deref(), data.pinned_url_string.as_deref())
    } else {
        match &data.pinned_url_string {
            Some(home) if !same(home, &data.url_string) => CorePatch::Set { value: home.clone() },
            _ => CorePatch::Unchanged,
        }
    }
}

fn order_plans(
    before: &[CoreSyncChange],
    after: &[CoreSyncChange],
    explicit_tab_ids: Option<HashSet<&str>>,
) -> Vec<OrderPlan> {
    let old_keys: HashSet<String> = before.iter().map(key_of).collect();
    let mut old_groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    for change in before {
        old_groups.entry(Container::of(change)).or_default().push(change);
    }
    let mut new_groups: HashMap<Container, Vec<&CoreSyncChange>> = HashMap::new();
    for change in after {
        new_groups.entry(Container::of(change)).or_default().push(change);
    }
    let mut seen = HashSet::new();
    let mut plans = Vec::new();
    for change in after {
        let list = Container::of(change);
        if !seen.insert(list.clone()) {
            continue;
        }
        let ids: Vec<String> = new_groups[&list].iter().map(|change| change.entity_id.clone()).collect();
        let old_indices: HashMap<&str, usize> = old_groups
            .get(&list)
            .into_iter()
            .flatten()
            .enumerate()
            .map(|(index, change)| (change.entity_id.as_str(), index))
            .collect();
        let kept = match &explicit_tab_ids {
            Some(explicit) if list != Container::Spaces => ids
                .iter()
                .filter(|id| !explicit.contains(id.as_str()) && old_keys.contains(&list.key(id)))
                .cloned()
                .collect(),
            _ => {
                let candidates: Vec<(&String, usize)> =
                    ids.iter().filter_map(|id| old_indices.get(id.as_str()).map(|&index| (id, index))).collect();
                longest_increasing_subsequence(&candidates).into_iter().cloned().collect()
            }
        };
        let created = ids.iter().filter(|id| !old_keys.contains(&list.key(id))).cloned().collect();
        plans.push(OrderPlan { container: list, ids, kept, created });
    }
    plans
}

fn explicit_tab_moves(
    plan: &OrderPlan,
    ordered_ids: &[String],
    next_by_key: &HashMap<String, &CoreSyncChange>,
) -> Vec<CoreSemanticOperation> {
    let anchors: HashSet<String> = plan.kept.union(&plan.created).cloned().collect();
    let next_anchors = following_anchors(&plan.ids, &anchors);
    let positions: HashMap<&str, usize> =
        ordered_ids.iter().enumerate().map(|(index, id)| (id.as_str(), index)).collect();
    let tab_data = |id: &str| next_by_key.get(&plan.container.key(id)).and_then(|change| change.tab_data.as_ref());
    let mut operations = Vec::new();
    let mut index = 0;
    while index < plan.ids.len() {
        if anchors.contains(&plan.ids[index]) {
            index += 1;
            continue;
        }
        let start = index;
        while index < plan.ids.len() && !anchors.contains(&plan.ids[index]) {
            index += 1;
        }
        // A new hinted identity is a create and an anchor, not a redundant move.
        let mut group: Vec<&String> = plan.ids[start..index].iter().collect();
        group.sort_by_key(|id| positions.get(id.as_str()).copied().unwrap_or(usize::MAX));
        let before_id = next_anchors[index - 1].cloned();
        let mut after_id = (start > 0).then(|| plan.ids[start - 1].clone());
        let mut offset = 0;
        while offset < group.len() {
            let Some(first) = tab_data(group[offset]) else { break };
            let destination = CoreSyncTabDestination { space_id: first.space_id.clone(), placement: first.placement };
            let chunk_start = offset;
            // Favorites share one rank order but may keep different historical Space IDs; a reorder does
            // not rewrite those IDs.
            while offset < group.len()
                && offset - chunk_start < 1000
                && tab_data(group[offset]).is_some_and(|data| {
                    same(&data.space_id, &destination.space_id) && data.placement == destination.placement
                })
            {
                offset += 1;
            }
            let chunk: Vec<String> = group[chunk_start..offset].iter().map(|id| (*id).clone()).collect();
            let last = chunk.last().cloned();
            operations.push(CoreSemanticOperation::MoveTabs {
                ids: chunk,
                destination,
                before_id: before_id.clone(),
                after_id,
            });
            after_id = last;
        }
    }
    operations
}

/// Unique identities reduce the longest common subsequence to an O(n log n) longest increasing one.
pub fn longest_increasing_subsequence<T: Copy + Eq + std::hash::Hash>(candidates: &[(T, usize)]) -> HashSet<T> {
    let mut tails: Vec<usize> = Vec::new();
    let mut predecessors = vec![usize::MAX; candidates.len()];
    for index in 0..candidates.len() {
        let (mut low, mut high) = (0, tails.len());
        while low < high {
            let middle = (low + high) / 2;
            if candidates[tails[middle]].1 < candidates[index].1 {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if low > 0 {
            predecessors[index] = tails[low - 1];
        }
        if low == tails.len() {
            tails.push(index);
        } else {
            tails[low] = index;
        }
    }
    let mut result = HashSet::new();
    let mut index = tails.last().copied().unwrap_or(usize::MAX);
    while index != usize::MAX {
        result.insert(candidates[index].0);
        index = predecessors[index];
    }
    result
}

/// For each position, the next anchor after it.
pub fn following_anchors<'a, T: Eq + std::hash::Hash>(ids: &'a [T], anchors: &HashSet<T>) -> Vec<Option<&'a T>> {
    let mut result = vec![None; ids.len()];
    let mut following = None;
    for index in (0..ids.len()).rev() {
        result[index] = following;
        if anchors.contains(&ids[index]) {
            following = Some(&ids[index]);
        }
    }
    result
}

// MARK: - Replay

/// Applies operations to canonical values as the server does, skipping what it would reject.
pub fn apply(
    operations: &[CoreSemanticOperation],
    values: &mut HashMap<String, CoreSyncChange>,
    deleted: &mut HashSet<String>,
) {
    for operation in operations {
        match operation {
            CoreSemanticOperation::CreateSpace { id, data, before_id, after_id } => {
                let entity_key = Container::Spaces.key(id);
                if deleted.contains(&entity_key) || live(&entity_key, values, deleted).is_some() {
                    continue;
                }
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
                insert(vec![change], &Container::Spaces, before_id.as_deref(), after_id.as_deref(), values, deleted);
            }
            CoreSemanticOperation::CreateTab { id, data, before_id, after_id } => {
                let entity_key = key(CoreSyncEntityType::Tab, id);
                let destination = Container::tab(&data.space_id, data.placement);
                if deleted.contains(&entity_key)
                    || live(&entity_key, values, deleted).is_some()
                    || !valid(&destination, values, deleted)
                {
                    continue;
                }
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
                        pinned_folder_id: None,
                    },
                );
                insert(vec![change], &destination, before_id.as_deref(), after_id.as_deref(), values, deleted);
            }
            CoreSemanticOperation::PatchSpace { id, fields } => {
                let entity_key = Container::Spaces.key(id);
                let Some(data) = live(&entity_key, values, deleted).and_then(|old| old.space_data.as_ref()) else {
                    continue;
                };
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
                values.insert(entity_key, change);
            }
            CoreSemanticOperation::PatchTab { id, fields } => {
                let entity_key = key(CoreSyncEntityType::Tab, id);
                let Some(data) = live(&entity_key, values, deleted).and_then(|old| old.tab_data.as_ref()) else {
                    continue;
                };
                let activity = fields.last_activity_at.applied(data.last_activity_at.as_deref());
                let change = CoreSyncChange::tab(
                    id,
                    CoreSyncTabPayload {
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
                        pinned_folder_id: None,
                    },
                );
                values.insert(entity_key, change);
            }
            CoreSemanticOperation::MoveSpaces { ids, before_id, after_id } => {
                move_entities(
                    ids,
                    &Container::Spaces,
                    None,
                    before_id.as_deref(),
                    after_id.as_deref(),
                    values,
                    deleted,
                );
            }
            CoreSemanticOperation::MoveTabs { ids, destination, before_id, after_id } => move_entities(
                ids,
                &Container::tab(&destination.space_id, destination.placement),
                Some(destination),
                before_id.as_deref(),
                after_id.as_deref(),
                values,
                deleted,
            ),
            CoreSemanticOperation::DeleteSpace { id } => remove(CoreSyncEntityType::Space, id, values, deleted),
            CoreSemanticOperation::DeleteTab { id } => remove(CoreSyncEntityType::Tab, id, values, deleted),
        }
    }
}

fn live<'a>(
    key: &str,
    values: &'a HashMap<String, CoreSyncChange>,
    deleted: &HashSet<String>,
) -> Option<&'a CoreSyncChange> {
    if deleted.contains(key) {
        return None;
    }
    values.get(key).filter(|value| value.op == CoreSyncOp::Upsert)
}

fn valid(destination: &Container, values: &HashMap<String, CoreSyncChange>, deleted: &HashSet<String>) -> bool {
    let Container::Tabs { space_id, .. } = destination else { return true };
    live(&Container::Spaces.key(space_id), values, deleted).is_some_and(|space| space.space_data.is_some())
}

fn list(
    container: &Container,
    values: &HashMap<String, CoreSyncChange>,
    deleted: &HashSet<String>,
) -> Vec<CoreSyncChange> {
    // Each rank is read once: reading it in the comparator copied the payloads on every comparison.
    let mut entries: Vec<(f64, &CoreSyncChange)> = values
        .values()
        .filter(|change| {
            change.op == CoreSyncOp::Upsert && container.holds(change) && !deleted.contains(&key_of(change))
        })
        .map(|change| (change.space_or_tab_rank().unwrap_or(0.0), change))
        .collect();
    entries.sort_by(|(left_rank, left), (right_rank, right)| {
        if left_rank == right_rank {
            order(&left.entity_id, &right.entity_id)
        } else if left_rank < right_rank {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Greater
        }
    });
    entries.into_iter().map(|(_, change)| change.clone()).collect()
}

/// Ranks the container in order. Entries that already hold their rank stay as they are; `written` names
/// the moved or new ones, which always go in.
fn publish(ordered: Vec<CoreSyncChange>, values: &mut HashMap<String, CoreSyncChange>, written: &HashSet<String>) {
    for (rank, change) in ordered.into_iter().enumerate() {
        let rank = rank as f64;
        if change.space_or_tab_rank() == Some(rank) && !written.contains(&change.entity_id) {
            continue;
        }
        values.insert(key_of(&change), replacing_rank(&change, Some(rank)));
    }
}

fn insert(
    group: Vec<CoreSyncChange>,
    destination: &Container,
    before_id: Option<&str>,
    after_id: Option<&str>,
    values: &mut HashMap<String, CoreSyncChange>,
    deleted: &HashSet<String>,
) {
    // One container holds one entity type, so IDs tell its entries apart.
    let moved: HashSet<String> = group.iter().map(|change| change.entity_id.clone()).collect();
    let mut siblings: Vec<CoreSyncChange> =
        list(destination, values, deleted).into_iter().filter(|change| !moved.contains(&change.entity_id)).collect();
    let before = before_id.and_then(|id| siblings.iter().position(|change| change.entity_id == id));
    let after =
        after_id.and_then(|id| siblings.iter().position(|change| change.entity_id == id).map(|index| index + 1));
    let at = before.or(after).unwrap_or(siblings.len());
    siblings.splice(at..at, group);
    publish(siblings, values, &moved);
}

fn move_entities(
    ids: &[String],
    destination: &Container,
    tab_destination: Option<&CoreSyncTabDestination>,
    before_id: Option<&str>,
    after_id: Option<&str>,
    values: &mut HashMap<String, CoreSyncChange>,
    deleted: &HashSet<String>,
) {
    if !valid(destination, values, deleted) {
        return;
    }
    let mut seen = HashSet::new();
    let survivors: Vec<CoreSyncChange> = ids
        .iter()
        .filter(|id| seen.insert(id.as_str()))
        .filter_map(|id| live(&destination.key(id), values, deleted).cloned())
        .collect();
    if survivors.is_empty() {
        return;
    }
    let moved: HashSet<String> = survivors.iter().map(|change| change.entity_id.clone()).collect();
    let sources: HashSet<Container> = survivors.iter().map(Container::of).collect();
    for source in sources {
        if source != *destination {
            let remaining = list(&source, values, deleted)
                .into_iter()
                .filter(|change| !moved.contains(&change.entity_id))
                .collect();
            publish(remaining, values, &HashSet::new());
        }
    }
    let group = survivors
        .into_iter()
        .map(|change| {
            let (Some(target), Some(data)) = (tab_destination, &change.tab_data) else { return change };
            let home = if target.placement == CoreTabPlacement::SpacePinned {
                if data.placement == CoreTabPlacement::SpacePinned {
                    data.pinned_url_string.clone()
                } else {
                    Some(data.url_string.clone())
                }
            } else {
                None
            };
            CoreSyncChange::tab(
                &change.entity_id,
                CoreSyncTabPayload {
                    space_id: target.space_id.clone(),
                    placement: target.placement,
                    rank: data.rank,
                    url_string: data.url_string.clone(),
                    pinned_url_string: home,
                    title: data.title.clone(),
                    user_title_override: data.user_title_override.clone(),
                    favicon_url_string: data.favicon_url_string.clone(),
                    last_activity_at: data.last_activity_at.clone(),
                    pinned_folder_id: None,
                },
            )
        })
        .collect();
    insert(group, destination, before_id, after_id, values, deleted);
}

fn remove(
    entity_type: CoreSyncEntityType,
    id: &str,
    values: &mut HashMap<String, CoreSyncChange>,
    deleted: &mut HashSet<String>,
) {
    let entity_key = key(entity_type, id);
    let old = values.get(&entity_key).cloned();
    deleted.insert(entity_key.clone());
    values.insert(entity_key, CoreSyncChange::deleted(entity_type, id));
    if entity_type == CoreSyncEntityType::Space {
        // Membership is read now, after earlier queued move-outs. Favorites are global and never part of a
        // Space's cascade.
        let children: Vec<(String, String)> = values
            .values()
            .filter(|change| change.op == CoreSyncOp::Upsert)
            .filter(|change| {
                change
                    .tab_data
                    .as_ref()
                    .is_some_and(|data| same(&data.space_id, id) && data.placement != CoreTabPlacement::App)
            })
            .map(|change| (key_of(change), change.entity_id.clone()))
            .collect();
        for (child_key, child_id) in children {
            deleted.insert(child_key.clone());
            values.insert(child_key, CoreSyncChange::deleted(CoreSyncEntityType::Tab, &child_id));
        }
    }
    if let Some(old) = old
        && old.op == CoreSyncOp::Upsert
    {
        let container = Container::of(&old);
        publish(list(&container, values, deleted), values, &HashSet::new());
    }
}
