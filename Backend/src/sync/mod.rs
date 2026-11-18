//! Account sync: devices, push with immutable receipts, paged pull, and the
//! canonical event log. Every push runs under the account row lock, so event
//! sequence numbers follow commit order and tombstone checks are serialized.

mod boosts;
mod events;
mod folders;
mod operations;
mod store;

pub use events::{Outcome, SyncEvent, legacy_events, v4_event};
pub use store::SyncStore;

use crate::account::{AppleTokens, store_apple_grant};
use crate::auth::AuthService;
use crate::error::{ApiError, ApiResult};
use crate::js_json;
use crate::signin::{Identity, create_session, resolve_user};
use crate::time::js_iso;
use deadpool_postgres::Pool;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashSet};
use tokio_postgres::Row;
use uuid::Uuid;

const EXPIRY_RESPONSE_LIMIT: usize = 4 * 1024 * 1024;

pub struct SyncService {
    pool: Pool,
    auth: AuthService,
    apple: AppleTokens,
}

/// The receipt digest covers the parsed protocol and ordered changes or
/// operations; the replaceable device ID and the mutation ID are excluded.
pub fn receipt_payload(request: &Value) -> Value {
    let mut payload = Map::new();
    let version = request.get("protocolVersion").and_then(Value::as_f64);
    if let Some(version) = request.get("protocolVersion") {
        payload.insert("protocolVersion".to_string(), version.clone());
    }
    if matches!(version, Some(3.0 | 4.0 | 5.0 | 6.0)) {
        payload.insert("operations".to_string(), request.get("operations").cloned().unwrap_or(Value::Null));
    } else {
        payload.insert("changes".to_string(), request.get("changes").cloned().unwrap_or(Value::Null));
    }
    Value::Object(payload)
}

impl SyncService {
    pub fn new(pool: Pool, auth: AuthService, apple: AppleTokens) -> Self {
        Self { pool, auth, apple }
    }

    /// Native Sign in with Apple. The account is the Apple identity's, as for
    /// every other sign-in method.
    pub async fn authenticate_with_apple(&self, body: &Value) -> ApiResult<Value> {
        let apple = self.auth.verify_apple_identity_token(text(body, "identityToken")).await?;
        let code = body.get("authorizationCode").and_then(Value::as_str);
        let grant = self.apple.redeem(&apple.audience, code, None, &apple.apple_subject).await;
        let identity = Identity {
            provider: "apple",
            subject: apple.apple_subject,
            email: apple.email,
            email_verified: apple.email_verified,
        };
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let user_id = resolve_user(&tx, &identity).await?;
        store_apple_grant(&tx, &identity.subject, grant.as_ref()).await?;
        let session =
            create_session(&tx, &self.auth, user_id, text(body, "deviceName"), text(body, "devicePlatform")).await?;
        tx.commit().await?;
        Ok(session)
    }

    pub async fn register_device(&self, user_id: Uuid, body: &Value) -> ApiResult<Value> {
        let client = self.pool.get().await?;
        let public_key = body.get("publicKey").and_then(Value::as_str);
        // A token outlives a deleted account; its account must still exist.
        let device = client
            .query_opt(
                "INSERT INTO devices (user_id, name, platform, public_key)
                 SELECT id, $2, $3, $4 FROM app_users WHERE id = $1
                 RETURNING id, name, platform, public_key, last_seen_at, created_at",
                &[&user_id, &text(body, "name"), &text(body, "platform"), &public_key],
            )
            .await?
            .ok_or(ApiError::Unauthorized)?;
        Ok(json!({"device": serialize_device(&device)}))
    }

    pub async fn push(&self, user_id: Uuid, body: &Value) -> ApiResult<Value> {
        let device_id = parse_uuid(text(body, "deviceID"))?;
        let protocol = body.get("protocolVersion").and_then(Value::as_f64).map(|version| version as u8);
        let mutation_id = body.get("mutationID").and_then(Value::as_str);
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        assert_device_belongs_to_user(&tx, user_id, device_id).await?;
        // Sequence allocation must follow commit order within an account.
        // Without this lock a later transaction can commit first and a pull
        // skips the earlier uncommitted events forever. It also serializes
        // tombstone checks.
        tx.execute("SELECT id FROM app_users WHERE id = $1 FOR UPDATE", &[&user_id]).await?;

        let digest = mutation_id.map(|_| js_json::digest(&receipt_payload(body)));
        if let Some(mutation_id) = mutation_id {
            let mutation_uuid = parse_uuid(mutation_id)?;
            let receipt = tx
                .query_opt(
                    "SELECT payload_digest, response FROM sync_mutation_receipts WHERE user_id = $1 AND mutation_id = $2",
                    &[&user_id, &mutation_uuid],
                )
                .await?;
            if let Some(receipt) = receipt {
                let stored: String = receipt.get("payload_digest");
                if Some(&stored) != digest.as_ref() {
                    return Err(ApiError::Conflict("Mutation ID was already used for different content".to_string()));
                }
                let response: Value = receipt.get("response");
                tx.commit().await?;
                return Ok(response);
            }
        }

        let store = SyncStore::new(&tx, user_id, device_id);
        // Legacy writers cannot create folders. Snapshot only Space IDs once
        // under the account lock, then invalidate after a Space cascade.
        let mut legacy_folder_spaces = HashSet::new();
        if !matches!(protocol, Some(4..=6)) {
            for row in tx
                .query("SELECT DISTINCT space_id FROM folders WHERE user_id = $1 AND deleted_at IS NULL", &[&user_id])
                .await?
            {
                legacy_folder_spaces.insert(row.get::<_, String>("space_id"));
            }
        }
        let mut events: Vec<SyncEvent> = Vec::new();
        let mut outcomes: Vec<Outcome> = Vec::new();
        let operations = body.get("operations").and_then(Value::as_array).cloned().unwrap_or_default();
        match protocol {
            Some(6) => {
                let executor = boosts::BoostExecutor::new(&store);
                for (index, operation) in operations.iter().enumerate() {
                    let (operation_events, outcome) = executor.apply(operation, index).await?;
                    events.extend(operation_events);
                    outcomes.push(outcome);
                }
            }
            Some(5) => {
                let mut budget = ExpiryBudget::default();
                for (index, operation) in operations.iter().enumerate() {
                    let (operation_events, outcome) = store.expire_tab(operation, index, &mut budget).await?;
                    events.extend(operation_events);
                    outcomes.push(outcome);
                }
            }
            Some(4) => {
                let executor = folders::FolderExecutor::new(&store);
                for (index, operation) in operations.iter().enumerate() {
                    let (operation_events, outcome) = executor.apply(operation, index).await?;
                    events.extend(operation_events);
                    outcomes.push(outcome);
                }
            }
            Some(3) => {
                let mut executor = operations::OperationExecutor::new(&store, &mut legacy_folder_spaces);
                for (index, operation) in operations.iter().enumerate() {
                    if executor.requires_upgrade(operation) {
                        let ids: Vec<String> = if operation.get("kind") == Some(&json!("move")) {
                            strings(operation.get("entityIDs"))
                        } else {
                            operation.get("entityID").and_then(Value::as_str).map(str::to_string).into_iter().collect()
                        };
                        for id in ids {
                            if let Some(current) = store.current_event("tab", &id).await? {
                                events.push(current);
                            }
                        }
                        outcomes.push(Outcome::rejected(index, "upgrade_required"));
                        continue;
                    }
                    let (operation_events, outcome) = executor.apply(operation, index).await?;
                    events.extend(operation_events);
                    outcomes.push(outcome);
                }
            }
            _ => {
                // Legacy snapshot diffs put deleted spaces before surviving
                // moved tabs.
                let changes = body.get("changes").and_then(Value::as_array).cloned().unwrap_or_default();
                let ordered = changes
                    .iter()
                    .filter(|change| change.get("op") == Some(&json!("upsert")))
                    .chain(changes.iter().filter(|change| change.get("op") == Some(&json!("delete"))));
                for change in ordered {
                    let change = events::Change::from_value(change);
                    events.extend(store.apply_change(&change, 2, Some(&mut legacy_folder_spaces)).await?);
                }
            }
        }

        tx.execute("UPDATE devices SET last_seen_at = now() WHERE id = $1", &[&device_id]).await?;
        let cursor: i64 = tx
            .query_one(
                "SELECT COALESCE(MAX(server_seq), 0)::bigint AS cursor FROM sync_events WHERE user_id = $1",
                &[&user_id],
            )
            .await?
            .get("cursor");
        // An acknowledgement is not a pull: events may include old
        // authoritative deletes. Clients advance their pull cursor only after
        // reading pull.
        let is_semantic = matches!(protocol, Some(3..=6));
        let mut visible = if matches!(protocol, Some(4..=6)) {
            events.iter().map(v4_event).collect::<Vec<_>>()
        } else {
            legacy_events(&events)
        };
        if is_semantic {
            // One event per sequence number: the first copy keeps its place in
            // the map and takes the last copy's content, as a JavaScript Map does.
            let mut unique: BTreeMap<i64, SyncEvent> = BTreeMap::new();
            for event in visible {
                unique.insert(event.server_seq, event);
            }
            visible = unique.into_values().collect();
        } else {
            visible.sort_by_key(|event| event.server_seq);
        }
        let mut response = Map::new();
        response.insert("cursor".to_string(), json!(cursor));
        response.insert("events".to_string(), Value::Array(visible.iter().map(SyncEvent::to_value).collect()));
        if let Some(mutation_id) = mutation_id {
            response.insert("protocolVersion".to_string(), json!(protocol.unwrap_or_default()));
            response.insert("mutationID".to_string(), json!(mutation_id));
        }
        if is_semantic {
            response.insert("outcomes".to_string(), Value::Array(outcomes.iter().map(Outcome::to_value).collect()));
        }
        let response = Value::Object(response);
        if protocol == Some(5) && js_json::byte_length(&response) > EXPIRY_RESPONSE_LIMIT {
            return Err(ApiError::Internal(anyhow::anyhow!("Expiry response exceeded its reserved budget")));
        }
        if let (Some(mutation_id), Some(digest)) = (mutation_id, &digest) {
            tx.execute(
                "INSERT INTO sync_mutation_receipts (user_id, mutation_id, payload_digest, response) VALUES ($1, $2, $3, $4)",
                &[&user_id, &parse_uuid(mutation_id)?, digest, &events::JsJson(&response)],
            )
            .await?;
        }
        tx.commit().await?;
        Ok(response)
    }

    pub async fn pull(&self, user_id: Uuid, body: &Value) -> ApiResult<Value> {
        let device_id = parse_uuid(text(body, "deviceID"))?;
        let protocol = body.get("protocolVersion").and_then(Value::as_f64).map(|version| version as u8);
        let cursor = body.get("cursor").and_then(Value::as_f64).unwrap_or_default() as i64;
        let limit = body.get("limit").and_then(Value::as_f64).unwrap_or(500.0) as i64;
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let device = tx
            .query_opt(
                "SELECT folder_sync_enabled, expiry_sync_enabled, boost_sync_enabled
                 FROM devices WHERE id = $1 AND user_id = $2 FOR UPDATE",
                &[&device_id, &user_id],
            )
            .await?;
        let Some(device) = device else { return Err(missing_device(&tx, user_id).await) };
        let is_v4 = protocol == Some(4);
        let is_v6 = protocol == Some(6);
        // Version 6 reads everything version 5 reads, plus boosts.
        let is_v5 = protocol == Some(5) || is_v6;
        let includes_folders = is_v4 || is_v5;
        if is_v6
            && !(device.get::<_, bool>("boost_sync_enabled") && device.get::<_, bool>("expiry_sync_enabled"))
            && cursor != 0
        {
            return Err(ApiError::Conflict("Protocol 6 bootstrap requires cursor 0".to_string()));
        }
        if is_v5 && !device.get::<_, bool>("expiry_sync_enabled") && cursor != 0 {
            return Err(ApiError::Conflict("Protocol 5 bootstrap requires cursor 0".to_string()));
        }
        if is_v4 && !device.get::<_, bool>("folder_sync_enabled") && cursor != 0 {
            return Err(ApiError::Conflict("Protocol 4 bootstrap requires cursor 0".to_string()));
        }
        let rows = tx
            .query(
                "SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
                 FROM sync_events
                 WHERE user_id = $1 AND server_seq > $2 AND ($4 OR entity_type <> 'folder')
                   AND ($5 OR entity_type <> 'boost')
                 ORDER BY server_seq ASC
                 LIMIT $3",
                &[&user_id, &cursor, &limit, &includes_folders, &is_v6],
            )
            .await?;
        let raw = rows.iter().map(SyncEvent::from_row).collect::<Vec<_>>();
        let events = if includes_folders { raw.iter().map(v4_event).collect::<Vec<_>>() } else { legacy_events(&raw) };
        let next_cursor = events.last().map_or(cursor, |event| event.server_seq);
        tx.execute(
            "UPDATE devices SET last_seen_at = now(), folder_sync_enabled = $2, expiry_sync_enabled = $3,
               boost_sync_enabled = $4 WHERE id = $1",
            &[&device_id, &includes_folders, &is_v5, &is_v6],
        )
        .await?;
        tx.commit().await?;
        Ok(json!({
            "protocolVersion": if is_v6 { 6 } else if is_v5 { 5 } else if is_v4 { 4 } else { 2 },
            "supportedPushVersions": [2, 3, 4, 5, 6],
            "cursor": next_cursor,
            "events": events.iter().map(SyncEvent::to_value).collect::<Vec<_>>(),
        }))
    }
}

async fn assert_device_belongs_to_user(
    tx: &deadpool_postgres::Transaction<'_>,
    user_id: Uuid,
    device_id: Uuid,
) -> ApiResult<()> {
    let found = tx.query_opt("SELECT 1 FROM devices WHERE id = $1 AND user_id = $2", &[&device_id, &user_id]).await?;
    if found.is_none() {
        return Err(missing_device(tx, user_id).await);
    }
    Ok(())
}

/// A device the account does not have is forbidden; an account that was
/// deleted is unauthorized, so its other devices learn they are signed out.
async fn missing_device(tx: &deadpool_postgres::Transaction<'_>, user_id: Uuid) -> ApiError {
    match tx.query_opt("SELECT 1 FROM app_users WHERE id = $1", &[&user_id]).await {
        Ok(Some(_)) => ApiError::Forbidden("Device does not belong to user".to_string()),
        Ok(None) => ApiError::Unauthorized,
        Err(error) => error.into(),
    }
}

/// Bounds a version 5 acknowledgement: every irreversible expiry must fit
/// together with its echo before it happens.
#[derive(Default)]
pub struct ExpiryBudget {
    bytes: usize,
    sequences: HashSet<i64>,
}

impl ExpiryBudget {
    // At most 100 small outcomes plus the response envelope fit well below this.
    const EVENT_LIMIT: usize = EXPIRY_RESPONSE_LIMIT - 64 * 1024;

    fn used(&self) -> usize {
        // Array brackets.
        self.bytes + 2
    }

    /// Includes the actual identity and payload strings, and reserves the
    /// fixed serverSeq/createdAt metadata before the irreversible operation.
    pub fn can_delete(&self, entity_id: &str, device_id: &str, payload: &Value) -> bool {
        let bytes = js_json::byte_length(&json!({
            "entityType": "tab", "entityID": entity_id, "deviceID": device_id, "op": "delete", "data": payload,
        }));
        self.used() + bytes + 512 < Self::EVENT_LIMIT
    }

    pub fn include(&mut self, events: &[SyncEvent]) -> bool {
        let mut unseen: Vec<&SyncEvent> = Vec::new();
        for event in events {
            if self.sequences.contains(&event.server_seq) {
                continue;
            }
            if let Some(position) = unseen.iter().position(|seen| seen.server_seq == event.server_seq) {
                unseen[position] = event;
            } else {
                unseen.push(event);
            }
        }
        let bytes: usize = unseen.iter().map(|event| js_json::byte_length(&event.to_value()) + 1).sum();
        if self.used() + bytes > Self::EVENT_LIMIT {
            return false;
        }
        self.bytes += bytes;
        self.sequences.extend(unseen.iter().map(|event| event.server_seq));
        true
    }
}

pub(crate) fn serialize_device(row: &Row) -> Value {
    let mut device = Map::new();
    device.insert("id".to_string(), json!(row.get::<_, Uuid>("id").to_string()));
    device.insert("name".to_string(), json!(row.get::<_, String>("name")));
    device.insert("platform".to_string(), json!(row.get::<_, String>("platform")));
    if let Some(public_key) = row.get::<_, Option<String>>("public_key") {
        device.insert("publicKey".to_string(), json!(public_key));
    }
    device.insert("lastSeenAt".to_string(), json!(js_iso(row.get("last_seen_at"))));
    Value::Object(device)
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect()
}

pub fn parse_uuid(text: &str) -> ApiResult<Uuid> {
    Uuid::parse_str(text).map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid uuid {text:?}: {error}")))
}
