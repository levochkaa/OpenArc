//! Version 4 operations: one order for mixed folder and tab siblings. The
//! service owns the transaction, account lock, receipts and delete cascades.

use super::events::{Change, Obj, Outcome, SyncEvent};
use super::operations::same_data;
use super::store::{Entity, SyncStore, columns, entity_from_row, spread};
use crate::js_json;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq)]
enum Container {
    Spaces,
    Tabs { space_id: String, placement: String, pinned_folder_id: Option<String> },
}

impl Container {
    fn key(&self) -> String {
        match self {
            Self::Spaces => "spaces".to_string(),
            Self::Tabs { space_id, placement, pinned_folder_id } => {
                let space = if placement == "app" { Value::Null } else { json!(space_id) };
                js_json::stringify(&json!([placement, space, pinned_folder_id]))
            }
        }
    }

    fn from_value(value: &Value) -> Self {
        if value.get("kind") == Some(&json!("spaces")) {
            return Self::Spaces;
        }
        Self::Tabs {
            space_id: value.get("spaceID").and_then(Value::as_str).unwrap_or_default().to_string(),
            placement: value.get("placement").and_then(Value::as_str).unwrap_or_default().to_string(),
            pinned_folder_id: value.get("pinnedFolderID").and_then(Value::as_str).map(str::to_string),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Reference {
    entity_type: &'static str,
    entity_id: String,
}

impl Reference {
    fn from_value(value: &Value) -> Self {
        Self {
            entity_type: static_type(value.get("entityType").and_then(Value::as_str).unwrap_or_default()),
            entity_id: value.get("entityID").and_then(Value::as_str).unwrap_or_default().to_string(),
        }
    }

    fn of(entity: &Entity) -> Self {
        Self { entity_type: entity.entity_type, entity_id: entity.entity_id.clone() }
    }

    /// `JSON.stringify([entityType, entityID])`, which also orders ties.
    fn key(&self) -> String {
        js_json::stringify(&json!([self.entity_type, self.entity_id]))
    }
}

type Result = anyhow::Result<(Vec<SyncEvent>, Outcome)>;

pub struct FolderExecutor<'s, 'a> {
    store: &'s SyncStore<'a>,
}

impl<'s, 'a> FolderExecutor<'s, 'a> {
    pub fn new(store: &'s SyncStore<'a>) -> Self {
        Self { store }
    }

    pub async fn apply(&self, operation: &Value, operation_index: usize) -> Result {
        let kind = operation.get("kind").and_then(Value::as_str).unwrap_or_default();
        if kind == "move" {
            return self.move_entities(operation, operation_index).await;
        }
        let reference = Reference::from_value(operation);
        if let Some(deleted) = self.store.tombstone_event(reference.entity_type, &reference.entity_id).await? {
            return Ok((vec![deleted], Outcome::new(operation_index, "deleted")));
        }
        let existing = self.read_entities(std::slice::from_ref(&reference)).await?.into_iter().next();

        if kind == "delete" {
            let mut events = self.apply_change(&Change::delete(reference.entity_type, &reference.entity_id)).await?;
            if let Some(existing) = &existing {
                let siblings = self.read_container(&container(existing)).await?;
                events.extend(self.publish_order(&siblings, &by_key(&siblings)).await?);
            }
            return Ok((events, Outcome::new(operation_index, "applied")));
        }
        if kind == "patch" {
            let Some(existing) = existing else { return Ok(rejected(operation_index, "missing", Vec::new())) };
            let fields = operation.get("fields").and_then(Value::as_object).cloned().unwrap_or_default();
            let next = Entity { data: spread(&existing.data, &fields), ..existing.clone() };
            return Ok((self.publish_entity(&next, Some(&existing)).await?, Outcome::new(operation_index, "applied")));
        }
        if let Some(existing) = existing {
            return Ok(rejected(
                operation_index,
                "entity_exists",
                self.current_events(&[Reference::of(&existing)]).await?,
            ));
        }
        let mut data: Obj = operation.get("data").and_then(Value::as_object).cloned().unwrap_or_default();
        data.insert("rank".to_string(), json!(0.0));
        let entity = Entity { entity_type: reference.entity_type, entity_id: reference.entity_id, data };
        let destination = container(&entity);
        if let Some((reason, events)) = self.validate_destination(&destination).await? {
            return Ok(rejected(operation_index, reason, events));
        }
        let siblings = self.read_container(&destination).await?;
        let ordered = insert(&siblings, &[entity], operation.get("before"), operation.get("after"));
        Ok((self.publish_order(&ordered, &by_key(&siblings)).await?, Outcome::new(operation_index, "applied")))
    }

    async fn move_entities(&self, operation: &Value, operation_index: usize) -> Result {
        let items: Vec<Reference> =
            operation.get("items").and_then(Value::as_array).into_iter().flatten().map(Reference::from_value).collect();
        let found = by_key(&self.read_entities(&items).await?);
        let survivors: Vec<Entity> = items.iter().filter_map(|item| found.get(&item.key()).cloned()).collect();
        let mut events = Vec::new();
        for item in items.iter().filter(|item| !found.contains_key(&item.key())) {
            if let Some(deleted) = self.store.tombstone_event(item.entity_type, &item.entity_id).await? {
                events.push(deleted);
            }
        }
        let destination = Container::from_value(operation.get("destination").unwrap_or(&Value::Null));
        let invalid = survivors.iter().any(|entity| match &destination {
            Container::Spaces => entity.entity_type != "space",
            Container::Tabs { placement, .. } => {
                entity.entity_type == "space" || (entity.entity_type == "folder" && placement != "spacePinned")
            }
        });
        let references: Vec<Reference> = survivors.iter().map(Reference::of).collect();
        if invalid {
            events.extend(self.current_events(&references).await?);
            return Ok(rejected(operation_index, "invalid_destination", events));
        }
        if let Some((reason, failure_events)) = self.validate_destination(&destination).await? {
            events.extend(failure_events);
            events.extend(self.current_events(&references).await?);
            return Ok(rejected(operation_index, reason, events));
        }
        if survivors.is_empty() {
            return Ok(if events.is_empty() {
                rejected(operation_index, "missing", events)
            } else {
                (events, Outcome::new(operation_index, "deleted"))
            });
        }

        let roots: Vec<&Entity> = survivors.iter().filter(|entity| entity.entity_type == "folder").collect();
        let root_ids: Vec<String> = roots.iter().map(|entity| entity.entity_id.clone()).collect();
        let subtree = self.read_folder_subtrees(&root_ids).await?;
        let subtree_ids: HashSet<String> = subtree.iter().map(|entity| entity.entity_id.clone()).collect();
        // Explicit selection of a parent and its child is ambiguous. Carrying
        // the parent's current subtree is one intent; reject the mixed group.
        let overlapping = survivors.iter().any(|entity| match entity.entity_type {
            "folder" => entity.str("parentFolderID").is_some_and(|parent| subtree_ids.contains(parent)),
            "tab" => {
                entity.str("placement") == Some("spacePinned")
                    && entity.str("pinnedFolderID").is_some_and(|folder| subtree_ids.contains(folder))
            }
            _ => false,
        });
        if overlapping {
            events.extend(self.current_events(&references).await?);
            return Ok(rejected(operation_index, "overlapping_items", events));
        }
        if let Container::Tabs { pinned_folder_id: Some(folder), .. } = &destination
            && subtree_ids.contains(folder)
        {
            events.extend(self.current_events(&references).await?);
            return Ok(rejected(operation_index, "cycle", events));
        }
        let descendants = parent_first(&subtree, &root_ids);
        if descendants.len() != subtree.len() {
            events.extend(self.current_events(&references).await?);
            return Ok(rejected(operation_index, "cycle", events));
        }

        let moved_keys: HashSet<String> = references.iter().map(Reference::key).collect();
        let mut sources: Vec<(String, Container)> = Vec::new();
        for entity in &survivors {
            let source = container(entity);
            let key = source.key();
            if let Some(entry) = sources.iter_mut().find(|(existing, _)| *existing == key) {
                entry.1 = source;
            } else {
                sources.push((key, source));
            }
        }
        let target_rows = self.read_container(&destination).await?;
        let mut originals = by_key(&target_rows);
        for entity in &survivors {
            originals.insert(Reference::of(entity).key(), entity.clone());
        }
        let moved: Vec<Entity> = survivors.iter().map(|entity| moved_entity(entity, &destination)).collect();
        // Every destination, overlap and cycle check precedes the first write.
        let destination_key = destination.key();
        for (key, source) in &sources {
            if *key == destination_key {
                continue;
            }
            let rows = self.read_container(source).await?;
            let remaining: Vec<Entity> =
                rows.iter().filter(|entity| !moved_keys.contains(&Reference::of(entity).key())).cloned().collect();
            events.extend(self.publish_order(&remaining, &by_key(&rows)).await?);
        }
        let remaining: Vec<Entity> =
            target_rows.iter().filter(|entity| !moved_keys.contains(&Reference::of(entity).key())).cloned().collect();
        let ordered = insert(&remaining, &moved, operation.get("before"), operation.get("after"));
        events.extend(self.publish_order(&ordered, &originals).await?);
        if let Container::Tabs { space_id, .. } = &destination {
            // Root folders have already moved. Publish parents before
            // children, then tabs, so parent validation never observes a
            // stale space ID.
            let root_set: HashSet<&String> = root_ids.iter().collect();
            for folder in &descendants {
                if root_set.contains(&folder.entity_id) || folder.str("spaceID") == Some(space_id.as_str()) {
                    continue;
                }
                let mut data = folder.data.clone();
                data.insert("spaceID".to_string(), json!(space_id));
                events.extend(self.publish_entity(&Entity { data, ..folder.clone() }, None).await?);
            }
            let subtree_list: Vec<String> = subtree_ids.iter().cloned().collect();
            for tab in self.read_folder_tabs(&subtree_list).await? {
                if tab.str("spaceID") == Some(space_id.as_str()) {
                    continue;
                }
                let mut data = tab.data.clone();
                data.insert("spaceID".to_string(), json!(space_id));
                events.extend(self.publish_entity(&Entity { data, ..tab.clone() }, None).await?);
            }
        }
        events.extend(self.current_events(&references).await?);
        Ok((events, Outcome::new(operation_index, "applied")))
    }

    async fn validate_destination(
        &self,
        container: &Container,
    ) -> anyhow::Result<Option<(&'static str, Vec<SyncEvent>)>> {
        let Container::Tabs { space_id, placement, pinned_folder_id } = container else { return Ok(None) };
        if placement != "spacePinned" && pinned_folder_id.is_some() {
            return Ok(Some(("invalid_destination", Vec::new())));
        }
        if placement == "app" {
            return Ok(None);
        }
        if let Some(deleted) = self.store.tombstone_event("space", space_id).await? {
            return Ok(Some(("target_deleted", vec![deleted])));
        }
        let space = Reference { entity_type: "space", entity_id: space_id.clone() };
        if self.read_entities(&[space]).await?.is_empty() {
            return Ok(Some(("target_missing", Vec::new())));
        }
        let mut seen = HashSet::new();
        let mut parent = pinned_folder_id.clone();
        while let Some(folder_id) = parent {
            if !seen.insert(folder_id.clone()) {
                return Ok(Some(("cycle", Vec::new())));
            }
            if let Some(deleted) = self.store.tombstone_event("folder", &folder_id).await? {
                return Ok(Some(("target_deleted", vec![deleted])));
            }
            let reference = Reference { entity_type: "folder", entity_id: folder_id };
            let Some(folder) = self.read_entities(&[reference]).await?.into_iter().next() else {
                return Ok(Some(("target_missing", Vec::new())));
            };
            if folder.str("spaceID") != Some(space_id.as_str()) {
                return Ok(Some(("target_wrong_space", self.current_events(&[Reference::of(&folder)]).await?)));
            }
            parent = folder.str("parentFolderID").map(str::to_string);
        }
        Ok(None)
    }

    async fn publish_order(
        &self,
        ordered: &[Entity],
        originals: &HashMap<String, Entity>,
    ) -> anyhow::Result<Vec<SyncEvent>> {
        let mut events = Vec::new();
        for (rank, entity) in ordered.iter().enumerate() {
            let mut updated = entity.clone();
            updated.data.insert("rank".to_string(), js_json::number(rank as f64));
            if let Some(previous) = originals.get(&Reference::of(entity).key())
                && same_data(&previous.data, &updated.data)
            {
                continue;
            }
            events.extend(self.publish_entity(&updated, None).await?);
        }
        Ok(events)
    }

    async fn publish_entity(&self, entity: &Entity, previous: Option<&Entity>) -> anyhow::Result<Vec<SyncEvent>> {
        if let Some(previous) = previous
            && same_data(&previous.data, &entity.data)
        {
            return self.current_events(&[Reference::of(entity)]).await;
        }
        self.apply_change(&Change::upsert(entity.entity_type, &entity.entity_id, entity.data.clone())).await
    }

    async fn current_events(&self, references: &[Reference]) -> anyhow::Result<Vec<SyncEvent>> {
        let mut events = Vec::new();
        for reference in references {
            if let Some(event) = self.store.current_event(reference.entity_type, &reference.entity_id).await? {
                events.push(event);
            }
        }
        Ok(events)
    }

    async fn apply_change(&self, change: &Change) -> anyhow::Result<Vec<SyncEvent>> {
        self.store.apply_change(change, 4, None).await
    }

    async fn read_entities(&self, references: &[Reference]) -> anyhow::Result<Vec<Entity>> {
        let mut entities = Vec::new();
        for entity_type in ["space", "tab", "folder"] {
            let ids: Vec<String> = references
                .iter()
                .filter(|reference| reference.entity_type == entity_type)
                .map(|reference| reference.entity_id.clone())
                .collect();
            if !ids.is_empty() {
                entities.extend(self.store.read_entities(entity_type, &ids, true).await?);
            }
        }
        Ok(entities)
    }

    async fn read_container(&self, container: &Container) -> anyhow::Result<Vec<Entity>> {
        let user_id = &self.store.user_id;
        let Container::Tabs { space_id, placement, pinned_folder_id } = container else {
            let rows = self
                .store
                .query(
                    &format!(
                        "SELECT {} FROM spaces WHERE user_id = $1 AND deleted_at IS NULL ORDER BY rank, id",
                        columns("space")
                    ),
                    &[user_id],
                )
                .await?;
            return Ok(rows.iter().map(|row| entity_from_row("space", row, true)).collect());
        };
        let rows = match placement.as_str() {
            "app" => {
                self.store
                    .query(
                        &format!(
                            "SELECT {} FROM tabs WHERE user_id = $1 AND deleted_at IS NULL AND placement = $2",
                            columns("tab")
                        ),
                        &[user_id, placement],
                    )
                    .await?
            }
            "spacePinned" => self
                .store
                .query(
                    &format!(
                        "SELECT {} FROM tabs WHERE user_id = $1 AND deleted_at IS NULL AND placement = $2 \
                         AND space_id = $3 AND pinned_folder_id IS NOT DISTINCT FROM $4::text",
                        columns("tab")
                    ),
                    &[user_id, placement, space_id, pinned_folder_id],
                )
                .await?,
            _ => self
                .store
                .query(
                    &format!(
                        "SELECT {} FROM tabs WHERE user_id = $1 AND deleted_at IS NULL AND placement = $2 AND space_id = $3",
                        columns("tab")
                    ),
                    &[user_id, placement, space_id],
                )
                .await?,
        };
        let mut entities: Vec<Entity> = rows.iter().map(|row| entity_from_row("tab", row, true)).collect();
        if placement == "spacePinned" {
            let folders = self
                .store
                .query(
                    &format!(
                        "SELECT {} FROM folders WHERE user_id = $1 AND space_id = $2 AND deleted_at IS NULL \
                         AND parent_folder_id IS NOT DISTINCT FROM $3::text",
                        columns("folder")
                    ),
                    &[user_id, space_id, pinned_folder_id],
                )
                .await?;
            entities.extend(folders.iter().map(|row| entity_from_row("folder", row, true)));
        }
        // Rank, then the typed key, compared as JavaScript compares strings.
        entities.sort_by(|a, b| {
            let rank = |entity: &Entity| entity.data.get("rank").and_then(Value::as_f64).unwrap_or_default();
            rank(a)
                .partial_cmp(&rank(b))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| js_json::compare_utf16(&Reference::of(a).key(), &Reference::of(b).key()))
        });
        Ok(entities)
    }

    async fn read_folder_subtrees(&self, root_ids: &[String]) -> anyhow::Result<Vec<Entity>> {
        if root_ids.is_empty() {
            return Ok(Vec::new());
        }
        // UNION (not UNION ALL) also terminates if existing data has a cycle.
        let rows = self
            .store
            .query(
                &format!(
                    "WITH RECURSIVE subtree AS (
                       SELECT {columns} FROM folders WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL
                       UNION
                       SELECT {child} FROM folders child JOIN subtree parent ON child.parent_folder_id = parent.id
                       WHERE child.user_id = $1 AND child.deleted_at IS NULL
                     ) SELECT {columns} FROM subtree",
                    columns = columns("folder"),
                    child = columns("folder")
                        .split(", ")
                        .map(|column| format!("child.{column}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                &[&self.store.user_id, &root_ids],
            )
            .await?;
        Ok(rows.iter().map(|row| entity_from_row("folder", row, true)).collect())
    }

    async fn read_folder_tabs(&self, folder_ids: &[String]) -> anyhow::Result<Vec<Entity>> {
        if folder_ids.is_empty() {
            return Ok(Vec::new());
        }
        let rows = self
            .store
            .query(
                &format!(
                    "SELECT {} FROM tabs WHERE user_id = $1 AND placement = 'spacePinned' \
                     AND pinned_folder_id = ANY($2::text[]) AND deleted_at IS NULL ORDER BY id",
                    columns("tab")
                ),
                &[&self.store.user_id, &folder_ids],
            )
            .await?;
        Ok(rows.iter().map(|row| entity_from_row("tab", row, true)).collect())
    }
}

fn rejected(operation_index: usize, reason: &str, events: Vec<SyncEvent>) -> (Vec<SyncEvent>, Outcome) {
    (events, Outcome::rejected(operation_index, reason))
}

fn static_type(entity_type: &str) -> &'static str {
    match entity_type {
        "space" => "space",
        "folder" => "folder",
        _ => "tab",
    }
}

fn container(entity: &Entity) -> Container {
    match entity.entity_type {
        "space" => Container::Spaces,
        "folder" => Container::Tabs {
            space_id: entity.str("spaceID").unwrap_or_default().to_string(),
            placement: "spacePinned".to_string(),
            pinned_folder_id: entity.str("parentFolderID").map(str::to_string),
        },
        _ => {
            let placement = entity.str("placement").unwrap_or_default().to_string();
            let pinned_folder_id =
                if placement == "spacePinned" { entity.str("pinnedFolderID").map(str::to_string) } else { None };
            Container::Tabs {
                space_id: entity.str("spaceID").unwrap_or_default().to_string(),
                placement,
                pinned_folder_id,
            }
        }
    }
}

fn moved_entity(entity: &Entity, destination: &Container) -> Entity {
    let Container::Tabs { space_id, placement, pinned_folder_id } = destination else { return entity.clone() };
    let mut data = entity.data.clone();
    match entity.entity_type {
        "space" => return entity.clone(),
        "folder" => {
            data.insert("spaceID".to_string(), json!(space_id));
            data.insert("parentFolderID".to_string(), json!(pinned_folder_id));
        }
        _ => {
            let pinned_url = if placement != "spacePinned" {
                Value::Null
            } else if entity.str("placement") == Some("spacePinned") {
                entity.data.get("pinnedURLString").cloned().unwrap_or(Value::Null)
            } else {
                entity.data.get("urlString").cloned().unwrap_or(Value::Null)
            };
            data.insert("spaceID".to_string(), json!(space_id));
            data.insert("placement".to_string(), json!(placement));
            data.insert("pinnedFolderID".to_string(), json!(pinned_folder_id));
            data.insert("pinnedURLString".to_string(), pinned_url);
        }
    }
    Entity { data, ..entity.clone() }
}

/// Folders in breadth-first order from the roots: parents before children.
/// A folder unreachable from the roots signals a cycle in stored data.
fn parent_first(folders: &[Entity], root_ids: &[String]) -> Vec<Entity> {
    let by_id: HashMap<&str, &Entity> = folders.iter().map(|folder| (folder.entity_id.as_str(), folder)).collect();
    let mut children: HashMap<&str, Vec<&Entity>> = HashMap::new();
    for folder in folders {
        if let Some(parent) = folder.str("parentFolderID") {
            children.entry(parent).or_default().push(folder);
        }
    }
    let mut queue: Vec<&Entity> = root_ids.iter().filter_map(|id| by_id.get(id.as_str()).copied()).collect();
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    let mut index = 0;
    while index < queue.len() {
        let folder = queue[index];
        index += 1;
        if !seen.insert(folder.entity_id.as_str()) {
            continue;
        }
        result.push(folder.clone());
        if let Some(children) = children.get(folder.entity_id.as_str()) {
            queue.extend(children.iter().copied());
        }
    }
    result
}

fn by_key(entities: &[Entity]) -> HashMap<String, Entity> {
    entities.iter().map(|entity| (Reference::of(entity).key(), entity.clone())).collect()
}

fn insert(siblings: &[Entity], group: &[Entity], before: Option<&Value>, after: Option<&Value>) -> Vec<Entity> {
    let position = |anchor: Option<&Value>| {
        anchor.filter(|anchor| !anchor.is_null()).and_then(|anchor| {
            let key = Reference::from_value(anchor).key();
            siblings.iter().position(|entity| Reference::of(entity).key() == key)
        })
    };
    let index = position(before).or_else(|| position(after).map(|index| index + 1)).unwrap_or(siblings.len());
    let mut result = siblings[..index].to_vec();
    result.extend_from_slice(group);
    result.extend_from_slice(&siblings[index..]);
    result
}
