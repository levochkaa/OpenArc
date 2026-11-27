//! Version 7 mobile tabs: the tab list a phone or tablet keeps apart from
//! desktop Spaces. Each operation names one tab identity: an upsert replaces
//! the whole record, so the last committed write wins, except the activity
//! instant, which keeps the maximum as desktop tabs do; a delete leaves a
//! permanent tombstone, so a late upsert cannot bring the tab back.
//! The service owns the transaction, account lock and receipts.

use super::events::{Outcome, SyncEvent};
use super::store::SyncStore;
use serde_json::{Map, Value, json};

type Result = anyhow::Result<(Vec<SyncEvent>, Outcome)>;

pub struct MobileTabExecutor<'s, 'a> {
    store: &'s SyncStore<'a>,
}

impl<'s, 'a> MobileTabExecutor<'s, 'a> {
    pub fn new(store: &'s SyncStore<'a>) -> Self {
        Self { store }
    }

    pub async fn apply(&self, operation: &Value, operation_index: usize) -> Result {
        let entity_id = operation.get("entityID").and_then(Value::as_str).unwrap_or_default();
        if operation.get("kind") == Some(&json!("delete")) {
            let already_deleted = self.store.tombstone_event("mobileTab", entity_id).await?.is_some();
            let events = self.store.delete_entity("mobileTab", entity_id, None).await?;
            let status = if already_deleted { "deleted" } else { "applied" };
            return Ok((events, Outcome::new(operation_index, status)));
        }
        if let Some(deleted) = self.store.tombstone_event("mobileTab", entity_id).await? {
            return Ok((vec![deleted], Outcome::rejected(operation_index, "deleted")));
        }
        let data = operation.get("data").and_then(Value::as_object).cloned().unwrap_or_default();
        let text = |key: &str| data.get(key).and_then(Value::as_str);
        // An absent title clears the stored one; absent or older activity
        // cannot lower or erase a known value.
        let saved = self
            .store
            .query_one(
                "INSERT INTO mobile_tabs (id, user_id, url_string, title, created_at, last_activity_at,
                   deleted_at, updated_at, revision, updated_by_device_id)
                 VALUES ($1, $2, $3, $4, CAST($5::text AS timestamptz), CAST($6::text AS timestamptz),
                   NULL, now(), 1, $7)
                 ON CONFLICT (user_id, id) DO UPDATE SET url_string = EXCLUDED.url_string,
                   title = EXCLUDED.title, created_at = EXCLUDED.created_at,
                   last_activity_at = GREATEST(mobile_tabs.last_activity_at, EXCLUDED.last_activity_at),
                   updated_at = now(), revision = mobile_tabs.revision + 1,
                   updated_by_device_id = EXCLUDED.updated_by_device_id
                 RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS created_at,
                   to_char(last_activity_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS last_activity_at",
                &[
                    &entity_id,
                    &self.store.user_id,
                    &text("urlString").unwrap_or_default(),
                    &text("title"),
                    &text("createdAt").unwrap_or_default(),
                    &text("lastActivityAt"),
                    &self.store.device_id,
                ],
            )
            .await?;
        // The committed values, with PostgreSQL's microseconds; optional
        // fields stay absent when unset.
        let mut payload = Map::new();
        payload.insert("id".to_string(), json!(entity_id));
        payload.insert("urlString".to_string(), json!(text("urlString").unwrap_or_default()));
        payload.insert("createdAt".to_string(), json!(saved.get::<_, String>("created_at")));
        if let Some(activity) = saved.get::<_, Option<String>>("last_activity_at") {
            payload.insert("lastActivityAt".to_string(), json!(activity));
        }
        if let Some(title) = text("title") {
            payload.insert("title".to_string(), json!(title));
        }
        let event = self.store.insert_sync_event("mobileTab", entity_id, "upsert", &Value::Object(payload)).await?;
        Ok((vec![event], Outcome::new(operation_index, "applied")))
    }
}
