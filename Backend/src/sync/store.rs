//! Entity writes, tombstones and the event log inside one account-locked
//! push transaction.

use super::ExpiryBudget;
use super::events::{Change, JsJson, Obj, Outcome, SyncEvent, v4_event};
use crate::js_json;
use crate::time::js_iso;
use anyhow::{Context, anyhow, bail};
use chrono::{DateTime, Utc};
use deadpool_postgres::Transaction;
use postgres_types::{Timestamp, ToSql};
use serde_json::{Map, Value, json};
use std::collections::HashSet;
use tokio_postgres::Row;
use uuid::Uuid;

/// A space, tab or folder with its data in the order the original server
/// built it. The order matters only where data are compared as JSON text.
#[derive(Clone, Debug)]
pub struct Entity {
    pub entity_type: &'static str,
    pub entity_id: String,
    pub data: Obj,
}

impl Entity {
    pub fn str(&self, key: &str) -> Option<&str> {
        self.data.get(key).and_then(Value::as_str)
    }
}

pub struct SyncStore<'a> {
    tx: &'a Transaction<'a>,
    pub user_id: Uuid,
    pub device_id: Uuid,
}

type Params<'p> = &'p [&'p (dyn ToSql + Sync)];

impl<'a> SyncStore<'a> {
    pub fn new(tx: &'a Transaction<'a>, user_id: Uuid, device_id: Uuid) -> Self {
        Self { tx, user_id, device_id }
    }

    pub async fn query(&self, sql: &str, params: Params<'_>) -> anyhow::Result<Vec<Row>> {
        let statement = self.tx.prepare_cached(sql).await?;
        Ok(self.tx.query(&statement, params).await?)
    }

    pub async fn query_opt(&self, sql: &str, params: Params<'_>) -> anyhow::Result<Option<Row>> {
        let statement = self.tx.prepare_cached(sql).await?;
        Ok(self.tx.query_opt(&statement, params).await?)
    }

    pub async fn query_one(&self, sql: &str, params: Params<'_>) -> anyhow::Result<Row> {
        let statement = self.tx.prepare_cached(sql).await?;
        Ok(self.tx.query_one(&statement, params).await?)
    }

    pub async fn execute(&self, sql: &str, params: Params<'_>) -> anyhow::Result<u64> {
        let statement = self.tx.prepare_cached(sql).await?;
        Ok(self.tx.execute(&statement, params).await?)
    }

    // MARK: Events

    pub async fn current_event(&self, entity_type: &str, entity_id: &str) -> anyhow::Result<Option<SyncEvent>> {
        let row = self
            .query_opt(
                "SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
                 FROM sync_events WHERE user_id = $1 AND entity_type = $2 AND entity_id = $3
                 ORDER BY server_seq DESC LIMIT 1",
                &[&self.user_id, &entity_type, &entity_id],
            )
            .await?;
        Ok(row.as_ref().map(SyncEvent::from_row))
    }

    pub async fn tombstone_event(&self, entity_type: &str, entity_id: &str) -> anyhow::Result<Option<SyncEvent>> {
        let row = self
            .query_opt(
                "SELECT e.server_seq, e.device_id, e.entity_type, e.entity_id, e.op, e.payload, e.created_at
                 FROM sync_tombstones t JOIN sync_events e ON e.server_seq = t.server_seq
                 WHERE t.user_id = $1 AND t.entity_type = $2 AND t.entity_id = $3",
                &[&self.user_id, &entity_type, &entity_id],
            )
            .await?;
        Ok(row.as_ref().map(SyncEvent::from_row))
    }

    pub(super) async fn insert_sync_event(
        &self,
        entity_type: &str,
        entity_id: &str,
        op: &str,
        payload: &Value,
    ) -> anyhow::Result<SyncEvent> {
        let row = self
            .query_one(
                "INSERT INTO sync_events (user_id, device_id, entity_type, entity_id, op, payload)
                 VALUES ($1, $2, $3, $4, $5, $6)
                 RETURNING server_seq, device_id, entity_type, entity_id, op, payload, created_at",
                &[&self.user_id, &self.device_id, &entity_type, &entity_id, &op, &JsJson(payload)],
            )
            .await?;
        Ok(SyncEvent::from_row(&row))
    }

    // MARK: Writes

    /// Writes a snapshot-form change: deletes cascade and tombstone; upserts of
    /// a tombstoned entity return the tombstone instead.
    pub async fn apply_change(
        &self,
        change: &Change,
        protocol: u8,
        mut legacy_folder_spaces: Option<&mut HashSet<String>>,
    ) -> anyhow::Result<Vec<SyncEvent>> {
        let entity_id = change.entity_id.as_str();
        if change.op == "delete" {
            let events = self.delete_entity(&change.entity_type, entity_id, None).await?;
            if change.entity_type == "space"
                && let Some(spaces) = legacy_folder_spaces.as_deref_mut()
            {
                spaces.remove(entity_id);
            }
            return Ok(events);
        }

        if let Some(deleted) = self.tombstone_event(&change.entity_type, entity_id).await? {
            return Ok(vec![deleted]);
        }

        let data = change.data.clone().with_context(|| format!("{} upsert requires data", change.entity_type))?;
        match change.entity_type.as_str() {
            "space" => {
                self.execute(
                    "INSERT INTO spaces (
                       id, user_id, title, system_image_name, rank, is_pinned_section_collapsed,
                       selected_tab_id, deleted_at, updated_at, revision, updated_by_device_id
                     )
                     VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, now(), 1, $8)
                     ON CONFLICT (user_id, id)
                     DO UPDATE SET
                       title = EXCLUDED.title,
                       system_image_name = EXCLUDED.system_image_name,
                       rank = EXCLUDED.rank,
                       is_pinned_section_collapsed = EXCLUDED.is_pinned_section_collapsed,
                       selected_tab_id = EXCLUDED.selected_tab_id,
                       deleted_at = NULL,
                       updated_at = now(),
                       revision = spaces.revision + 1,
                       updated_by_device_id = EXCLUDED.updated_by_device_id",
                    &[
                        &entity_id,
                        &self.user_id,
                        &str_field(&data, "title"),
                        &str_field(&data, "systemImageName"),
                        &f64_field(&data, "rank"),
                        &data.get("isPinnedSectionCollapsed").and_then(Value::as_bool).unwrap_or(false),
                        &opt_str(&data, "selectedTabID"),
                        &self.device_id,
                    ],
                )
                .await?;
                let payload = Value::Object(with_id(entity_id, &data));
                Ok(vec![self.insert_sync_event("space", entity_id, "upsert", &payload).await?])
            }
            "folder" => {
                self.execute(
                    "INSERT INTO folders (id, user_id, space_id, parent_folder_id, title, system_image_name, rank,
                       deleted_at, updated_at, revision, updated_by_device_id)
                     VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, now(), 1, $8)
                     ON CONFLICT (user_id, id) DO UPDATE SET space_id = EXCLUDED.space_id,
                       parent_folder_id = EXCLUDED.parent_folder_id, title = EXCLUDED.title,
                       system_image_name = EXCLUDED.system_image_name, rank = EXCLUDED.rank,
                       deleted_at = NULL, updated_at = now(), revision = folders.revision + 1,
                       updated_by_device_id = EXCLUDED.updated_by_device_id",
                    &[
                        &entity_id,
                        &self.user_id,
                        &str_field(&data, "spaceID"),
                        &opt_str(&data, "parentFolderID"),
                        &str_field(&data, "title"),
                        &opt_str(&data, "systemImageName"),
                        &f64_field(&data, "rank"),
                        &self.device_id,
                    ],
                )
                .await?;
                let mut payload = with_id(entity_id, &data);
                let image = data.get("systemImageName").cloned().unwrap_or(Value::Null);
                payload.insert("systemImageName".to_string(), image);
                Ok(vec![self.insert_sync_event("folder", entity_id, "upsert", &Value::Object(payload)).await?])
            }
            _ => self.apply_tab_upsert(entity_id, data, protocol, legacy_folder_spaces.as_deref()).await,
        }
    }

    async fn apply_tab_upsert(
        &self,
        entity_id: &str,
        mut data: Obj,
        protocol: u8,
        legacy_folder_spaces: Option<&HashSet<String>>,
    ) -> anyhow::Result<Vec<SyncEvent>> {
        // Version 4's executor supplies canonical membership and home for every
        // existing row. Only a new create may omit home, which defaults to its
        // current URL.
        let existing = if protocol == 4 {
            None
        } else {
            self.query_opt(
                "SELECT space_id, placement, rank, pinned_url_string, pinned_folder_id
                 FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL",
                &[&self.user_id, &entity_id],
            )
            .await?
        };
        let existing_space = existing.as_ref().map(|row| row.get::<_, String>("space_id"));
        let existing_placement = existing.as_ref().map(|row| row.get::<_, String>("placement"));
        let has_folders = |space: &str| legacy_folder_spaces.is_some_and(|spaces| spaces.contains(space));
        if protocol != 4 {
            let source_has_folders = existing_placement.as_deref() == Some("spacePinned")
                && existing_space.as_deref().is_some_and(has_folders);
            let target_has_folders =
                str_field(&data, "placement") == "spacePinned" && has_folders(str_field(&data, "spaceID"));
            if let (true, Some(row)) = (protocol == 2 && (source_has_folders || target_has_folders), &existing) {
                // A version 2 snapshot has no structural intent. Keep the
                // current tree while accepting page metadata, even if a stale
                // snapshot claims another list.
                data.insert("spaceID".to_string(), json!(row.get::<_, String>("space_id")));
                data.insert("placement".to_string(), json!(row.get::<_, String>("placement")));
                data.insert("rank".to_string(), js_json::number(row.get("rank")));
                data.insert("pinnedURLString".to_string(), json!(row.get::<_, Option<String>>("pinned_url_string")));
            } else if let (true, Some(row)) = (source_has_folders, &existing)
                && str_field(&data, "placement") == "spacePinned"
                && existing_space.as_deref() == Some(str_field(&data, "spaceID"))
            {
                // Version 3 normalizes the whole flattened pinned list after
                // metadata writes and deletes. Keep mixed folder/tab sibling
                // ranks for those incidental writes.
                data.insert("rank".to_string(), js_json::number(row.get("rank")));
            } else if existing.is_none() && target_has_folders {
                let rank: f64 = self
                    .query_one(
                        "SELECT (COALESCE(MAX(rank), -1) + 1)::double precision AS rank FROM (
                           SELECT rank FROM tabs WHERE user_id = $1 AND space_id = $2 AND placement = 'spacePinned'
                             AND pinned_folder_id IS NULL AND deleted_at IS NULL
                           UNION ALL SELECT rank FROM folders WHERE user_id = $1 AND space_id = $2
                             AND parent_folder_id IS NULL AND deleted_at IS NULL
                         ) siblings",
                        &[&self.user_id, &str_field(&data, "spaceID")],
                    )
                    .await?
                    .get("rank");
                data.insert("rank".to_string(), js_json::number(rank));
            }
        }

        let space_id = str_field(&data, "spaceID").to_string();
        let placement = str_field(&data, "placement").to_string();
        let pinned_folder_id: Option<String> = if placement != "spacePinned" {
            None
        } else if protocol == 4 && data.contains_key("pinnedFolderID") {
            opt_str(&data, "pinnedFolderID").map(str::to_string)
        } else if existing_space.as_deref() == Some(space_id.as_str())
            && existing_placement.as_deref() == Some("spacePinned")
        {
            existing.as_ref().and_then(|row| row.get::<_, Option<String>>("pinned_folder_id"))
        } else {
            None
        };

        // Favorites are global. Their historical space ID is metadata, not a
        // lifetime owner; an explicit tab tombstone was already checked.
        if placement != "app" && self.tombstone_event("space", &space_id).await?.is_some() {
            // A tab moved out before the space deletion survives. A stale
            // snapshot must neither move it back into the deleted space nor
            // delete it there.
            let survivor = self
                .query_opt(
                    "SELECT 1 FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                     AND (space_id <> $3 OR placement = 'app')",
                    &[&self.user_id, &entity_id, &space_id],
                )
                .await?;
            if survivor.is_some() {
                return Ok(self.current_event("tab", entity_id).await?.into_iter().collect());
            }
            return self.delete_entity("tab", entity_id, None).await;
        }

        let pinned_url_string: Option<String> = if placement != "spacePinned" {
            None
        } else if data.contains_key("pinnedURLString") {
            opt_str(&data, "pinnedURLString").map(str::to_string)
        } else if let Some(row) = &existing {
            row.get::<_, Option<String>>("pinned_url_string")
        } else {
            Some(str_field(&data, "urlString").to_string())
        };

        let saved = self
            .query_one(
                "INSERT INTO tabs (
                   id, user_id, space_id, placement, rank, url_string, title, user_title_override,
                   favicon_url_string, last_activity_at, deleted_at, updated_at, revision, updated_by_device_id,
                   pinned_url_string, pinned_folder_id
                 )
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CAST($10::text AS timestamptz), NULL, now(), 1, $11, $12, $13)
                 ON CONFLICT (user_id, id)
                 DO UPDATE SET
                   space_id = EXCLUDED.space_id,
                   placement = EXCLUDED.placement,
                   rank = EXCLUDED.rank,
                   url_string = EXCLUDED.url_string,
                   pinned_url_string = EXCLUDED.pinned_url_string,
                   pinned_folder_id = EXCLUDED.pinned_folder_id,
                   title = EXCLUDED.title,
                   user_title_override = EXCLUDED.user_title_override,
                   favicon_url_string = EXCLUDED.favicon_url_string,
                   last_activity_at = GREATEST(tabs.last_activity_at, EXCLUDED.last_activity_at),
                   deleted_at = NULL,
                   updated_at = now(),
                   revision = tabs.revision + 1,
                   updated_by_device_id = EXCLUDED.updated_by_device_id
                 RETURNING to_char(last_activity_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS last_activity_at",
                &[
                    &entity_id,
                    &self.user_id,
                    &space_id,
                    &placement,
                    &f64_field(&data, "rank"),
                    &str_field(&data, "urlString"),
                    &opt_str(&data, "title"),
                    &opt_str(&data, "userTitleOverride"),
                    &opt_str(&data, "faviconURLString"),
                    &opt_str(&data, "lastActivityAt"),
                    &self.device_id,
                    &pinned_url_string,
                    &pinned_folder_id,
                ],
            )
            .await?;

        let mut payload = with_id(entity_id, &data);
        // The committed maximum, with PostgreSQL's microseconds.
        payload.insert("lastActivityAt".to_string(), json!(saved.get::<_, Option<String>>("last_activity_at")));
        payload.insert("pinnedURLString".to_string(), json!(pinned_url_string));
        payload.insert("pinnedFolderID".to_string(), json!(pinned_folder_id));
        Ok(vec![self.insert_sync_event("tab", entity_id, "upsert", &Value::Object(payload)).await?])
    }

    /// Deletes an entity and, for a space or folder, its current contents.
    /// An existing tombstone is returned instead of a second deletion.
    pub async fn delete_entity(
        &self,
        entity_type: &str,
        entity_id: &str,
        auto_archive: Option<Value>,
    ) -> anyhow::Result<Vec<SyncEvent>> {
        if auto_archive.is_some() && entity_type != "tab" {
            bail!("Only tab expiry can carry archive recovery data");
        }
        let mut events = Vec::new();
        if entity_type == "space" {
            // Include children in the event stream, even for clients that
            // already consumed the parent deletion before reconnecting with an
            // old snapshot.
            for child in self
                .query(
                    "SELECT id FROM tabs WHERE user_id = $1 AND space_id = $2 AND placement <> 'app'
                     AND deleted_at IS NULL ORDER BY id",
                    &[&self.user_id, &entity_id],
                )
                .await?
            {
                events.extend(Box::pin(self.delete_entity("tab", child.get("id"), None)).await?);
            }
            for folder in self
                .query(
                    "SELECT id FROM folders WHERE user_id = $1 AND space_id = $2 AND deleted_at IS NULL ORDER BY id",
                    &[&self.user_id, &entity_id],
                )
                .await?
            {
                events.extend(Box::pin(self.delete_entity("folder", folder.get("id"), None)).await?);
            }
        } else if entity_type == "folder" {
            for child in self
                .query(
                    "SELECT id FROM folders WHERE user_id = $1 AND parent_folder_id = $2 AND deleted_at IS NULL ORDER BY id",
                    &[&self.user_id, &entity_id],
                )
                .await?
            {
                events.extend(Box::pin(self.delete_entity("folder", child.get("id"), None)).await?);
            }
            for tab in self
                .query(
                    "SELECT id FROM tabs WHERE user_id = $1 AND pinned_folder_id = $2 AND deleted_at IS NULL ORDER BY id",
                    &[&self.user_id, &entity_id],
                )
                .await?
            {
                events.extend(Box::pin(self.delete_entity("tab", tab.get("id"), None)).await?);
            }
        }
        if let Some(previous) = self.tombstone_event(entity_type, entity_id).await? {
            events.push(previous);
            return Ok(events);
        }
        let table = match entity_type {
            "space" => "spaces",
            "folder" => "folders",
            "boost" => "boosts",
            "mobileTab" => "mobile_tabs",
            _ => "tabs",
        };
        self.execute(
            &format!(
                "UPDATE {table} SET deleted_at = now(), updated_at = now(),
                 revision = revision + 1, updated_by_device_id = $3 WHERE user_id = $1 AND id = $2"
            ),
            &[&self.user_id, &entity_id, &self.device_id],
        )
        .await?;
        let mut payload = Map::new();
        payload.insert("id".to_string(), json!(entity_id));
        if let Some(auto_archive) = auto_archive {
            payload.insert("autoArchive".to_string(), auto_archive);
        }
        let event = self.insert_sync_event(entity_type, entity_id, "delete", &Value::Object(payload)).await?;
        self.execute(
            "INSERT INTO sync_tombstones (user_id, entity_type, entity_id, server_seq) VALUES ($1, $2, $3, $4)",
            &[&self.user_id, &entity_type, &entity_id, &event.server_seq],
        )
        .await?;
        events.push(event);
        Ok(events)
    }

    /// Version 5 conditional expiry. The account lock covers the observed
    /// sequence, eligibility, recovery data, tombstone and receipt; server time
    /// chooses the cutoff, never a client clock.
    pub async fn expire_tab(
        &self,
        operation: &Value,
        operation_index: usize,
        budget: &mut ExpiryBudget,
    ) -> anyhow::Result<(Vec<SyncEvent>, Outcome)> {
        let entity_id = operation.get("entityID").and_then(Value::as_str).unwrap_or_default();
        let expected = operation.get("expectedServerSeq").and_then(Value::as_f64).unwrap_or_default() as i64;
        let inactive_for = operation.get("inactiveForSeconds").and_then(Value::as_f64).unwrap_or_default();
        let respond =
            |budget: &mut ExpiryBudget, events: Vec<SyncEvent>, status: &'static str, reason: Option<&str>| {
                let canonical = events.iter().map(v4_event).collect::<Vec<_>>();
                if budget.include(&canonical) {
                    let mut outcome = Outcome::new(operation_index, status);
                    outcome.reason = reason.map(str::to_string);
                    (canonical, outcome)
                } else {
                    (Vec::new(), Outcome::rejected(operation_index, "response_limit"))
                }
            };
        if let Some(deleted) = self.tombstone_event("tab", entity_id).await? {
            return Ok(respond(budget, vec![deleted], "deleted", None));
        }
        let current = self.current_event("tab", entity_id).await?;
        let rejected = |budget: &mut ExpiryBudget, reason: &str| {
            respond(budget, current.clone().into_iter().collect(), "rejected", Some(reason))
        };
        let tab = self
            .query_opt(
                "SELECT placement, last_activity_at IS NOT NULL AND isfinite(last_activity_at) AS known_activity,
                   last_activity_at <= now() - ($3::double precision * interval '1 second') AS expired,
                   to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS archived_at
                 FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL",
                &[&self.user_id, &entity_id, &inactive_for],
            )
            .await?;
        let Some(tab) = tab else { return Ok(rejected(budget, "missing")) };
        let Some(current_event) = current.as_ref().filter(|event| event.op == "upsert" && event.server_seq == expected)
        else {
            return Ok(rejected(budget, "state_changed"));
        };
        if tab.get::<_, String>("placement") != "temporary" {
            return Ok(rejected(budget, "not_temporary"));
        }
        if !tab.get::<_, bool>("known_activity") {
            return Ok(rejected(budget, "activity_unknown"));
        }
        if tab.get::<_, Option<bool>>("expired") != Some(true) {
            return Ok(rejected(budget, "not_expired"));
        }
        let data = v4_event(current_event).data;
        if !data.is_object() {
            bail!("Invalid canonical tab event");
        }
        let auto_archive = json!({
            "archivedAt": tab.get::<_, String>("archived_at"),
            "sourceServerSeq": current_event.server_seq,
            "tab": data,
        });
        let candidate = json!({"id": entity_id, "autoArchive": auto_archive});
        if !budget.can_delete(entity_id, &self.device_id.to_string(), &candidate) {
            return Ok((Vec::new(), Outcome::rejected(operation_index, "response_limit")));
        }
        // Rank gaps are valid. Renumbering peers here would invalidate another
        // candidate's observed sequence inside the same expiry batch.
        let events = self.delete_entity("tab", entity_id, Some(auto_archive)).await?;
        if !budget.include(&events) {
            return Err(anyhow!("Expiry event exceeded its reserved budget"));
        }
        Ok((events, Outcome::new(operation_index, "applied")))
    }

    // MARK: Entity reads for operation executors

    pub async fn read_entities(
        &self,
        entity_type: &'static str,
        ids: &[String],
        v4: bool,
    ) -> anyhow::Result<Vec<Entity>> {
        let table = table(entity_type);
        let rows = self
            .query(
                &format!(
                    "SELECT {} FROM {table} WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL",
                    columns(entity_type)
                ),
                &[&self.user_id, &ids],
            )
            .await?;
        Ok(rows.iter().map(|row| entity_from_row(entity_type, row, v4)).collect())
    }
}

/// The columns `entity_from_row` reads. Named instead of `*`, so a cached
/// statement survives a migration that adds a column.
pub fn columns(entity_type: &str) -> &'static str {
    match entity_type {
        "space" => "id, title, system_image_name, rank, is_pinned_section_collapsed, selected_tab_id",
        "folder" => "id, space_id, parent_folder_id, title, system_image_name, rank",
        _ => {
            "id, space_id, placement, rank, pinned_folder_id, url_string, pinned_url_string, title, \
             user_title_override, favicon_url_string, last_activity_at"
        }
    }
}

pub fn table(entity_type: &str) -> &'static str {
    match entity_type {
        "space" => "spaces",
        "folder" => "folders",
        _ => "tabs",
    }
}

/// Entity data from a row, with the keys in the original server's order.
/// Version 4 tabs also carry their folder.
pub fn entity_from_row(entity_type: &'static str, row: &Row, v4: bool) -> Entity {
    let mut data = Map::new();
    let text = |column: &str| json!(row.get::<_, String>(column));
    let optional = |column: &str| json!(row.get::<_, Option<String>>(column));
    match entity_type {
        "space" => {
            data.insert("title".into(), text("title"));
            data.insert("systemImageName".into(), text("system_image_name"));
            data.insert("rank".into(), js_json::number(row.get("rank")));
            data.insert("isPinnedSectionCollapsed".into(), json!(row.get::<_, bool>("is_pinned_section_collapsed")));
            data.insert("selectedTabID".into(), optional("selected_tab_id"));
        }
        "folder" => {
            data.insert("spaceID".into(), text("space_id"));
            data.insert("parentFolderID".into(), optional("parent_folder_id"));
            data.insert("title".into(), text("title"));
            data.insert("systemImageName".into(), optional("system_image_name"));
            data.insert("rank".into(), js_json::number(row.get("rank")));
        }
        _ => {
            data.insert("spaceID".into(), text("space_id"));
            data.insert("placement".into(), text("placement"));
            data.insert("rank".into(), js_json::number(row.get("rank")));
            if v4 {
                data.insert("pinnedFolderID".into(), optional("pinned_folder_id"));
            }
            data.insert("urlString".into(), text("url_string"));
            data.insert("pinnedURLString".into(), optional("pinned_url_string"));
            data.insert("title".into(), optional("title"));
            data.insert("userTitleOverride".into(), optional("user_title_override"));
            data.insert("faviconURLString".into(), optional("favicon_url_string"));
            let activity = match row.get::<_, Option<Timestamp<DateTime<Utc>>>>("last_activity_at") {
                Some(Timestamp::Value(timestamp)) => json!(js_iso(timestamp)),
                _ => Value::Null,
            };
            data.insert("lastActivityAt".into(), activity);
        }
    }
    Entity { entity_type, entity_id: row.get("id"), data }
}

/// `{...base, ...overrides}`: existing keys keep their place.
pub fn spread(base: &Obj, overrides: &Obj) -> Obj {
    let mut result = base.clone();
    for (key, value) in overrides {
        result.insert(key.clone(), value.clone());
    }
    result
}

fn with_id(entity_id: &str, data: &Obj) -> Obj {
    let mut payload = Map::new();
    payload.insert("id".to_string(), json!(entity_id));
    for (key, value) in data {
        payload.insert(key.clone(), value.clone());
    }
    payload
}

fn str_field<'d>(data: &'d Obj, key: &str) -> &'d str {
    data.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// `data[key] ?? null` as a string parameter.
fn opt_str<'d>(data: &'d Obj, key: &str) -> Option<&'d str> {
    data.get(key).and_then(Value::as_str)
}

fn f64_field(data: &Obj, key: &str) -> f64 {
    data.get(key).and_then(Value::as_f64).unwrap_or_default()
}
