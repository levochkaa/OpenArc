//! Version 3 semantic operations on spaces and tabs. The caller owns the
//! account transaction lock. Current rows are read before each operation, so
//! client metadata and ranks never replace unrelated concurrent edits.

use super::events::{Change, Obj, Outcome, SyncEvent, legacy_events};
use super::store::{Entity, SyncStore, columns, spread};
use crate::js_json;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq)]
enum Container {
    Spaces,
    Tabs { space_id: String, placement: String },
}

impl Container {
    fn key(&self) -> String {
        match self {
            Self::Spaces => "spaces".to_string(),
            Self::Tabs { space_id, placement } => {
                let space = if placement == "app" { Value::Null } else { json!(space_id) };
                js_json::stringify(&json!([placement, space]))
            }
        }
    }
}

type Result = anyhow::Result<(Vec<SyncEvent>, Outcome)>;

pub struct OperationExecutor<'s, 'a> {
    store: &'s SyncStore<'a>,
    legacy_folder_spaces: &'s mut HashSet<String>,
}

impl<'s, 'a> OperationExecutor<'s, 'a> {
    pub fn new(store: &'s SyncStore<'a>, legacy_folder_spaces: &'s mut HashSet<String>) -> Self {
        Self { store, legacy_folder_spaces }
    }

    /// Creating or moving a tab into the pinned list of a Space with folders
    /// needs a version 4 client.
    pub fn requires_upgrade(&self, operation: &Value) -> bool {
        if operation.get("entityType") != Some(&json!("tab")) {
            return false;
        }
        let destination = match operation.get("kind").and_then(Value::as_str) {
            Some("create") => operation.get("data"),
            Some("move") => operation.get("destination"),
            _ => None,
        };
        destination.is_some_and(|destination| {
            destination.get("placement") == Some(&json!("spacePinned"))
                && destination
                    .get("spaceID")
                    .and_then(Value::as_str)
                    .is_some_and(|space| self.legacy_folder_spaces.contains(space))
        })
    }

    pub async fn apply(&mut self, operation: &Value, operation_index: usize) -> Result {
        let kind = operation.get("kind").and_then(Value::as_str).unwrap_or_default();
        if kind == "move" {
            return self.move_entities(operation, operation_index).await;
        }
        let entity_type = entity_type(operation);
        let entity_id = operation.get("entityID").and_then(Value::as_str).unwrap_or_default().to_string();
        if let Some(deleted) = self.tombstone(entity_type, &entity_id).await? {
            return Ok((vec![deleted], Outcome::new(operation_index, "deleted")));
        }
        let existing = self.read_entities(entity_type, std::slice::from_ref(&entity_id)).await?.into_iter().next();

        if kind == "delete" {
            let mut events = self.apply_change(&Change::delete(entity_type, &entity_id)).await?;
            if let Some(existing) = &existing {
                let siblings = self.read_container(&container(existing)).await?;
                let originals = by_id(&siblings);
                events.extend(self.publish_order(&siblings, &originals).await?);
            }
            return Ok((events, Outcome::new(operation_index, "applied")));
        }

        if kind == "patch" {
            let Some(existing) = existing else {
                return Ok((Vec::new(), Outcome::rejected(operation_index, "missing")));
            };
            let fields = operation.get("fields").and_then(Value::as_object).cloned().unwrap_or_default();
            let next = Entity { data: spread(&existing.data, &fields), ..existing.clone() };
            return Ok((self.publish_entity(&next, Some(&existing)).await?, Outcome::new(operation_index, "applied")));
        }

        if let Some(existing) = existing {
            return Ok((self.current_events(&[existing]).await?, Outcome::rejected(operation_index, "entity_exists")));
        }
        let mut data: Obj = operation.get("data").and_then(Value::as_object).cloned().unwrap_or_default();
        data.insert("rank".to_string(), json!(0.0));
        let entity = Entity { entity_type, entity_id, data };
        let destination = container(&entity);
        if let Some((reason, events)) = self.validate_destination(&destination).await? {
            return Ok((events, Outcome::rejected(operation_index, reason)));
        }
        let siblings = self.read_container(&destination).await?;
        let ordered = insert(&siblings, &[entity], operation.get("beforeID"), operation.get("afterID"));
        let originals = by_id(&siblings);
        Ok((self.publish_order(&ordered, &originals).await?, Outcome::new(operation_index, "applied")))
    }

    async fn move_entities(&mut self, operation: &Value, operation_index: usize) -> Result {
        let entity_type = entity_type(operation);
        let ids: Vec<String> = operation
            .get("entityIDs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        let found = by_id(&self.read_entities(entity_type, &ids).await?);
        let survivors: Vec<Entity> = ids.iter().filter_map(|id| found.get(id).cloned()).collect();
        let mut events = Vec::new();
        for id in ids.iter().filter(|id| !found.contains_key(*id)) {
            if let Some(deleted) = self.tombstone(entity_type, id).await? {
                events.push(deleted);
            }
        }
        let destination = if entity_type == "space" {
            Container::Spaces
        } else {
            let target = operation.get("destination").cloned().unwrap_or(Value::Null);
            Container::Tabs {
                space_id: target.get("spaceID").and_then(Value::as_str).unwrap_or_default().to_string(),
                placement: target.get("placement").and_then(Value::as_str).unwrap_or_default().to_string(),
            }
        };
        if let Some((reason, failure_events)) = self.validate_destination(&destination).await? {
            events.extend(failure_events);
            events.extend(self.current_events(&survivors).await?);
            return Ok((events, Outcome::rejected(operation_index, reason)));
        }
        if survivors.is_empty() {
            let outcome = if events.is_empty() {
                Outcome::rejected(operation_index, "missing")
            } else {
                Outcome::new(operation_index, "deleted")
            };
            return Ok((events, outcome));
        }

        let moved_ids: HashSet<&String> = survivors.iter().map(|entity| &entity.entity_id).collect();
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
        let mut target_originals = by_id(&target_rows);
        for entity in &survivors {
            target_originals.insert(entity.entity_id.clone(), entity.clone());
        }
        let moved: Vec<Entity> = survivors
            .iter()
            .map(|entity| {
                let Container::Tabs { space_id, placement } = &destination else { return entity.clone() };
                if entity.entity_type != "tab" {
                    return entity.clone();
                }
                let pinned_url = if placement != "spacePinned" {
                    Value::Null
                } else if entity.str("placement") == Some("spacePinned") {
                    entity.data.get("pinnedURLString").cloned().unwrap_or(Value::Null)
                } else {
                    entity.data.get("urlString").cloned().unwrap_or(Value::Null)
                };
                let mut data = entity.data.clone();
                data.insert("spaceID".to_string(), json!(space_id));
                data.insert("placement".to_string(), json!(placement));
                data.insert("pinnedURLString".to_string(), pinned_url);
                Entity { data, ..entity.clone() }
            })
            .collect();
        let destination_key = destination.key();
        for (key, source) in &sources {
            if *key == destination_key {
                continue;
            }
            let originals = self.read_container(source).await?;
            let remaining: Vec<Entity> =
                originals.iter().filter(|entity| !moved_ids.contains(&entity.entity_id)).cloned().collect();
            events.extend(self.publish_order(&remaining, &by_id(&originals)).await?);
        }
        let remaining: Vec<Entity> =
            target_rows.iter().filter(|entity| !moved_ids.contains(&entity.entity_id)).cloned().collect();
        let ordered = insert(&remaining, &moved, operation.get("beforeID"), operation.get("afterID"));
        events.extend(self.publish_order(&ordered, &target_originals).await?);
        // Even a no-op move acknowledges the current authoritative state, so a
        // client can drop its optimistic overlay without waiting for a pull.
        events.extend(self.current_events(&survivors).await?);
        Ok((events, Outcome::new(operation_index, "applied")))
    }

    async fn validate_destination(
        &mut self,
        container: &Container,
    ) -> anyhow::Result<Option<(&'static str, Vec<SyncEvent>)>> {
        // Global Favorites do not depend on their historical space's lifetime.
        let Container::Tabs { space_id, placement } = container else { return Ok(None) };
        if placement == "app" {
            return Ok(None);
        }
        if let Some(deleted) = self.tombstone("space", space_id).await? {
            return Ok(Some(("target_deleted", vec![deleted])));
        }
        if self.read_entities("space", std::slice::from_ref(space_id)).await?.is_empty() {
            return Ok(Some(("target_missing", Vec::new())));
        }
        Ok(None)
    }

    async fn publish_order(
        &mut self,
        ordered: &[Entity],
        originals: &HashMap<String, Entity>,
    ) -> anyhow::Result<Vec<SyncEvent>> {
        let mut events = Vec::new();
        for (rank, entity) in ordered.iter().enumerate() {
            let mut updated = entity.clone();
            updated.data.insert("rank".to_string(), js_json::number(rank as f64));
            if let Some(previous) = originals.get(&entity.entity_id)
                && same_data(&previous.data, &updated.data)
            {
                continue;
            }
            events.extend(self.publish_entity(&updated, None).await?);
        }
        Ok(events)
    }

    async fn publish_entity(&mut self, entity: &Entity, previous: Option<&Entity>) -> anyhow::Result<Vec<SyncEvent>> {
        if let Some(previous) = previous
            && same_data(&previous.data, &entity.data)
        {
            return self.current_events(std::slice::from_ref(entity)).await;
        }
        self.apply_change(&Change::upsert(entity.entity_type, &entity.entity_id, entity.data.clone())).await
    }

    async fn current_events(&self, entities: &[Entity]) -> anyhow::Result<Vec<SyncEvent>> {
        let mut events = Vec::new();
        for entity in entities {
            if let Some(current) = self.store.current_event(entity.entity_type, &entity.entity_id).await? {
                events.extend(legacy_events(&[current]));
            }
        }
        Ok(events)
    }

    async fn apply_change(&mut self, change: &Change) -> anyhow::Result<Vec<SyncEvent>> {
        let events = self.store.apply_change(change, 3, Some(self.legacy_folder_spaces)).await?;
        Ok(legacy_events(&events))
    }

    async fn tombstone(&self, entity_type: &str, entity_id: &str) -> anyhow::Result<Option<SyncEvent>> {
        Ok(self
            .store
            .tombstone_event(entity_type, entity_id)
            .await?
            .map(|event| legacy_events(std::slice::from_ref(&event)).into_iter().next().unwrap_or(event)))
    }

    async fn read_entities(&self, entity_type: &'static str, ids: &[String]) -> anyhow::Result<Vec<Entity>> {
        self.store.read_entities(entity_type, ids, false).await
    }

    async fn read_container(&self, container: &Container) -> anyhow::Result<Vec<Entity>> {
        let (entity_type, rows) = match container {
            Container::Spaces => (
                "space",
                self.store
                    .query(
                        &format!(
                            "SELECT {} FROM spaces WHERE user_id = $1 AND deleted_at IS NULL ORDER BY rank, id",
                            columns("space")
                        ),
                        &[&self.store.user_id],
                    )
                    .await?,
            ),
            Container::Tabs { placement, .. } if placement == "app" => (
                "tab",
                self.store
                    .query(
                        &format!(
                            "SELECT {} FROM tabs WHERE user_id = $1 AND deleted_at IS NULL AND placement = $2 \
                             ORDER BY rank, id",
                            columns("tab")
                        ),
                        &[&self.store.user_id, placement],
                    )
                    .await?,
            ),
            Container::Tabs { space_id, placement } => (
                "tab",
                self.store
                    .query(
                        &format!(
                            "SELECT {} FROM tabs WHERE user_id = $1 AND deleted_at IS NULL AND placement = $2 \
                             AND space_id = $3 ORDER BY rank, id",
                            columns("tab")
                        ),
                        &[&self.store.user_id, placement, space_id],
                    )
                    .await?,
            ),
        };
        Ok(rows.iter().map(|row| super::store::entity_from_row(entity_type, row, false)).collect())
    }
}

fn entity_type(operation: &Value) -> &'static str {
    match operation.get("entityType").and_then(Value::as_str) {
        Some("space") => "space",
        _ => "tab",
    }
}

fn container(entity: &Entity) -> Container {
    if entity.entity_type == "space" {
        return Container::Spaces;
    }
    Container::Tabs {
        space_id: entity.str("spaceID").unwrap_or_default().to_string(),
        placement: entity.str("placement").unwrap_or_default().to_string(),
    }
}

fn by_id(entities: &[Entity]) -> HashMap<String, Entity> {
    entities.iter().map(|entity| (entity.entity_id.clone(), entity.clone())).collect()
}

/// `JSON.stringify(a) === JSON.stringify(b)`.
pub fn same_data(a: &Obj, b: &Obj) -> bool {
    js_json::stringify(&Value::Object(a.clone())) == js_json::stringify(&Value::Object(b.clone()))
}

/// The group goes before a live `before` anchor, else after a live `after`
/// anchor, else at the end.
fn insert(siblings: &[Entity], group: &[Entity], before: Option<&Value>, after: Option<&Value>) -> Vec<Entity> {
    let position = |anchor: Option<&Value>| {
        anchor.and_then(Value::as_str).and_then(|id| siblings.iter().position(|entity| entity.entity_id == id))
    };
    let index = position(before).or_else(|| position(after).map(|index| index + 1)).unwrap_or(siblings.len());
    let mut result = siblings[..index].to_vec();
    result.extend_from_slice(group);
    result.extend_from_slice(&siblings[index..]);
    result
}
