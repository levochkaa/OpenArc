use crate::js_json;
use crate::time::js_iso;
use bytes::{BufMut, BytesMut};
use postgres_types::{IsNull, ToSql, Type, accepts, to_sql_checked};
use serde_json::{Map, Value, json};
use tokio_postgres::Row;
use uuid::Uuid;

pub type Obj = Map<String, Value>;

/// One row of the canonical event log as clients receive it.
#[derive(Clone, Debug)]
pub struct SyncEvent {
    pub server_seq: i64,
    pub device_id: Option<String>,
    pub entity_type: String,
    pub entity_id: String,
    pub op: String,
    pub data: Value,
    pub created_at: String,
}

impl SyncEvent {
    pub fn from_row(row: &Row) -> Self {
        Self {
            server_seq: row.get("server_seq"),
            device_id: row.get::<_, Option<Uuid>>("device_id").map(|id| id.to_string()),
            entity_type: row.get("entity_type"),
            entity_id: row.get("entity_id"),
            op: row.get("op"),
            data: row.get("payload"),
            created_at: js_iso(row.get("created_at")),
        }
    }

    pub fn to_value(&self) -> Value {
        json!({
            "serverSeq": self.server_seq,
            "deviceID": self.device_id,
            "entityType": self.entity_type,
            "entityID": self.entity_id,
            "op": self.op,
            "data": self.data,
            "createdAt": self.created_at,
        })
    }

    fn is_tab_upsert_with_object(&self) -> bool {
        self.entity_type == "tab" && self.op == "upsert" && self.data.is_object()
    }
}

/// Space and tab events for readers before version 4: no folder, boost or
/// mobile tab events and no folder membership.
pub fn legacy_events(events: &[SyncEvent]) -> Vec<SyncEvent> {
    events
        .iter()
        .filter(|event| !matches!(event.entity_type.as_str(), "folder" | "boost" | "mobileTab"))
        .map(|event| {
            let mut result = event.clone();
            if event.is_tab_upsert_with_object()
                && let Value::Object(data) = &mut result.data
            {
                data.shift_remove("pinnedFolderID");
            }
            result
        })
        .collect()
}

/// Version 4 tab events always carry membership; history written before
/// folders existed has none.
pub fn v4_event(event: &SyncEvent) -> SyncEvent {
    let mut result = event.clone();
    if event.is_tab_upsert_with_object()
        && let Value::Object(data) = &mut result.data
    {
        let folder = data.get("pinnedFolderID").cloned().unwrap_or(Value::Null);
        data.insert("pinnedFolderID".to_string(), folder);
    }
    result
}

#[derive(Clone, Debug)]
pub struct Outcome {
    pub operation_index: usize,
    pub status: &'static str,
    pub reason: Option<String>,
}

impl Outcome {
    pub fn new(operation_index: usize, status: &'static str) -> Self {
        Self { operation_index, status, reason: None }
    }

    pub fn rejected(operation_index: usize, reason: &str) -> Self {
        Self { operation_index, status: "rejected", reason: Some(reason.to_string()) }
    }

    pub fn to_value(&self) -> Value {
        let mut value = Map::new();
        value.insert("operationIndex".to_string(), json!(self.operation_index));
        value.insert("status".to_string(), json!(self.status));
        if let Some(reason) = &self.reason {
            value.insert("reason".to_string(), json!(reason));
        }
        Value::Object(value)
    }
}

/// An entity write in snapshot form: an upsert with its data, or a delete.
#[derive(Clone, Debug)]
pub struct Change {
    pub entity_type: String,
    pub entity_id: String,
    pub op: String,
    pub data: Option<Obj>,
}

impl Change {
    pub fn from_value(value: &Value) -> Self {
        Self {
            entity_type: value.get("entityType").and_then(Value::as_str).unwrap_or_default().to_string(),
            entity_id: value.get("entityID").and_then(Value::as_str).unwrap_or_default().to_string(),
            op: value.get("op").and_then(Value::as_str).unwrap_or_default().to_string(),
            data: value.get("data").and_then(Value::as_object).cloned(),
        }
    }

    pub fn upsert(entity_type: &str, entity_id: &str, data: Obj) -> Self {
        Self {
            entity_type: entity_type.to_string(),
            entity_id: entity_id.to_string(),
            op: "upsert".to_string(),
            data: Some(data),
        }
    }

    pub fn delete(entity_type: &str, entity_id: &str) -> Self {
        Self {
            entity_type: entity_type.to_string(),
            entity_id: entity_id.to_string(),
            op: "delete".to_string(),
            data: None,
        }
    }
}

/// A JSON or JSONB parameter written as JavaScript wrote it.
#[derive(Debug)]
pub struct JsJson<'a>(pub &'a Value);

impl ToSql for JsJson<'_> {
    fn to_sql(&self, ty: &Type, out: &mut BytesMut) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        if *ty == Type::JSONB {
            out.put_u8(1);
        }
        out.put_slice(js_json::stringify(self.0).as_bytes());
        Ok(IsNull::No)
    }

    accepts!(JSON, JSONB);
    to_sql_checked!();
}
