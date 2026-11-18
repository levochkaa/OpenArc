//! Version 6 site boosts. Each operation names one boost identity: an upsert
//! replaces the whole record, name and styling included, so the last
//! committed write wins; a delete leaves a permanent tombstone, so a late
//! upsert cannot bring the boost back.
//! The service owns the transaction, account lock and receipts.

use super::events::{Outcome, SyncEvent};
use super::store::SyncStore;
use serde_json::{Map, Value, json};

type Result = anyhow::Result<(Vec<SyncEvent>, Outcome)>;

pub struct BoostExecutor<'s, 'a> {
    store: &'s SyncStore<'a>,
}

impl<'s, 'a> BoostExecutor<'s, 'a> {
    pub fn new(store: &'s SyncStore<'a>) -> Self {
        Self { store }
    }

    pub async fn apply(&self, operation: &Value, operation_index: usize) -> Result {
        let entity_id = operation.get("entityID").and_then(Value::as_str).unwrap_or_default();
        if operation.get("kind") == Some(&json!("delete")) {
            let already_deleted = self.store.tombstone_event("boost", entity_id).await?.is_some();
            let events = self.store.delete_entity("boost", entity_id, None).await?;
            let status = if already_deleted { "deleted" } else { "applied" };
            return Ok((events, Outcome::new(operation_index, status)));
        }
        if let Some(deleted) = self.store.tombstone_event("boost", entity_id).await? {
            return Ok((vec![deleted], Outcome::rejected(operation_index, "deleted")));
        }
        let data = operation.get("data").and_then(Value::as_object).cloned().unwrap_or_default();
        let text = |key: &str| data.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
        let selectors = data.get("zappedSelectors").cloned().unwrap_or_else(|| json!([]));
        // The upsert replaces the whole boost: an absent name or styling clears
        // what an earlier write stored.
        let title = data.get("title").and_then(Value::as_str);
        let style = data.get("style").filter(|style| style.is_object());
        self.store
            .execute(
                "INSERT INTO boosts (id, user_id, host, is_enabled, css, java_script, zapped_selectors, title, style,
                   deleted_at, updated_at, revision, updated_by_device_id)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $9, $10, NULL, now(), 1, $8)
                 ON CONFLICT (user_id, id) DO UPDATE SET host = EXCLUDED.host, is_enabled = EXCLUDED.is_enabled,
                   css = EXCLUDED.css, java_script = EXCLUDED.java_script,
                   zapped_selectors = EXCLUDED.zapped_selectors, title = EXCLUDED.title, style = EXCLUDED.style,
                   updated_at = now(), revision = boosts.revision + 1,
                   updated_by_device_id = EXCLUDED.updated_by_device_id",
                &[
                    &entity_id,
                    &self.store.user_id,
                    &text("host"),
                    &data.get("isEnabled").and_then(Value::as_bool).unwrap_or(true),
                    &text("css"),
                    &text("javaScript"),
                    &selectors,
                    &self.store.device_id,
                    &title,
                    &style,
                ],
            )
            .await?;
        let mut payload = Map::new();
        payload.insert("id".to_string(), json!(entity_id));
        for key in ["host", "isEnabled", "css", "javaScript", "zappedSelectors"] {
            payload.insert(key.to_string(), data.get(key).cloned().unwrap_or(Value::Null));
        }
        // Optional fields stay absent, as the client sent them.
        if let Some(title) = title {
            payload.insert("title".to_string(), json!(title));
        }
        if let Some(style) = style {
            payload.insert("style".to_string(), style.clone());
        }
        let event = self.store.insert_sync_event("boost", entity_id, "upsert", &Value::Object(payload)).await?;
        Ok((vec![event], Outcome::new(operation_index, "applied")))
    }
}
