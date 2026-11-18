//! Shared links: a snapshot of a Space's or folder's pinned tabs, or a quote
//! from a page, published by a signed-in account and readable by anyone with
//! the link. Sharing the same Space, folder or quote again updates its link.

mod content;
pub mod page;

pub use content::{Kind, Normalized, normalize};

use crate::error::{ApiError, ApiResult};
use crate::time::js_iso;
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use serde_json::{Map, Value, json};
use tokio_postgres::Row;
use uuid::Uuid;

/// Publishes per account in the last hour, updates included.
pub const PUBLISHES_PER_HOUR: i64 = 60;
/// Live links per account.
pub const MAX_SHARES: i64 = 1000;
pub const ID_LENGTH: usize = 10;
const ID_ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// A share as anyone with its link reads it.
pub struct Share {
    pub id: String,
    pub kind: Kind,
    pub content: Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub struct ShareService {
    pool: Pool,
    base_url: String,
}

impl ShareService {
    /// `base_url` is where the public pages live, such as `https://openarc.su`.
    pub fn new(pool: Pool, base_url: &str) -> Self {
        Self { pool, base_url: base_url.trim_end_matches('/').to_string() }
    }

    pub fn page_url(&self, kind: Kind, id: &str) -> String {
        format!("{}/{}/{id}", self.base_url, kind.path())
    }

    /// Creates the link, or updates the one this Space, folder or quote has.
    pub async fn publish(&self, user_id: Uuid, body: &Value) -> ApiResult<Value> {
        let share = normalize(body).map_err(ApiError::BadRequest)?;
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        if tx.query_opt("SELECT 1 FROM app_users WHERE id = $1", &[&user_id]).await?.is_none() {
            return Err(ApiError::Unauthorized);
        }
        // Publishes of one account take turns, so the limits hold.
        tx.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", &[&format!("shares:{user_id}")]).await?;
        tx.execute(
            "DELETE FROM share_publishes WHERE user_id = $1 AND published_at <= now() - interval '1 hour'",
            &[&user_id],
        )
        .await?;
        let recent: i64 =
            tx.query_one("SELECT count(*) FROM share_publishes WHERE user_id = $1", &[&user_id]).await?.get(0);
        if recent >= PUBLISHES_PER_HOUR {
            return Err(ApiError::status(429, "Too many shared links this hour; try again later"));
        }
        let kind = share.kind.name();
        let updated = tx
            .query_opt(
                "UPDATE shares SET title = $4, excerpt = $5, item_count = $6, content = $7, updated_at = now()
                 WHERE user_id = $1 AND kind = $2 AND source_id = $3
                 RETURNING id, kind, source_id, title, excerpt, item_count, created_at, updated_at",
                &[&user_id, &kind, &share.source_id, &share.title, &share.excerpt, &share.item_count, &share.content],
            )
            .await?;
        let row = match updated {
            Some(row) => row,
            None => {
                let count: i64 =
                    tx.query_one("SELECT count(*) FROM shares WHERE user_id = $1", &[&user_id]).await?.get(0);
                if count >= MAX_SHARES {
                    return Err(ApiError::status(
                        429,
                        format!("You have {MAX_SHARES} shared links; remove some before sharing more"),
                    ));
                }
                self.insert(&tx, user_id, &share).await?
            }
        };
        tx.execute("INSERT INTO share_publishes (user_id) VALUES ($1)", &[&user_id]).await?;
        tx.commit().await?;
        Ok(self.summary(&row))
    }

    async fn insert(
        &self,
        tx: &deadpool_postgres::Transaction<'_>,
        user_id: Uuid,
        share: &Normalized,
    ) -> ApiResult<Row> {
        // A new identifier until one is free; a collision is unlikely.
        for _ in 0..8 {
            let id = random_id()?;
            let row = tx
                .query_opt(
                    "INSERT INTO shares (id, user_id, kind, source_id, title, excerpt, item_count, content)
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                     ON CONFLICT (id) DO NOTHING
                     RETURNING id, kind, source_id, title, excerpt, item_count, created_at, updated_at",
                    &[
                        &id,
                        &user_id,
                        &share.kind.name(),
                        &share.source_id,
                        &share.title,
                        &share.excerpt,
                        &share.item_count,
                        &share.content,
                    ],
                )
                .await?;
            if let Some(row) = row {
                return Ok(row);
            }
        }
        Err(ApiError::Internal(anyhow::anyhow!("no free share identifier")))
    }

    /// The account's links, the most recently shared first.
    pub async fn list(&self, user_id: Uuid) -> ApiResult<Value> {
        let client = self.pool.get().await?;
        let rows = client
            .query(
                "SELECT id, kind, source_id, title, excerpt, item_count, created_at, updated_at
                 FROM shares WHERE user_id = $1 ORDER BY updated_at DESC, id",
                &[&user_id],
            )
            .await?;
        Ok(json!({"shares": rows.iter().map(|row| self.summary(row)).collect::<Vec<_>>()}))
    }

    /// Removes the link at once; its page then says so.
    pub async fn delete(&self, user_id: Uuid, id: &str) -> ApiResult<()> {
        if !is_share_id(id) {
            return Err(not_found());
        }
        let client = self.pool.get().await?;
        let deleted = client.execute("DELETE FROM shares WHERE id = $1 AND user_id = $2", &[&id, &user_id]).await?;
        if deleted == 0 { Err(not_found()) } else { Ok(()) }
    }

    pub async fn find(&self, id: &str) -> ApiResult<Option<Share>> {
        if !is_share_id(id) {
            return Ok(None);
        }
        let client = self.pool.get().await?;
        let row =
            client.query_opt("SELECT kind, content, created_at, updated_at FROM shares WHERE id = $1", &[&id]).await?;
        Ok(row.and_then(|row| {
            Some(Share {
                id: id.to_string(),
                kind: Kind::parse(row.get("kind"))?,
                content: row.get("content"),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            })
        }))
    }

    /// The content anyone with the link can read, for importing.
    pub fn public_json(&self, share: &Share) -> Value {
        let mut object = Map::new();
        object.insert("id".to_string(), json!(share.id));
        object.insert("kind".to_string(), json!(share.kind.name()));
        object.insert("shareURL".to_string(), json!(self.page_url(share.kind, &share.id)));
        if let Value::Object(content) = &share.content {
            for (key, value) in content {
                object.insert(key.clone(), value.clone());
            }
        }
        object.insert("createdAt".to_string(), json!(js_iso(share.created_at)));
        object.insert("updatedAt".to_string(), json!(js_iso(share.updated_at)));
        Value::Object(object)
    }

    fn summary(&self, row: &Row) -> Value {
        let id: String = row.get("id");
        let kind = Kind::parse(row.get("kind")).unwrap_or(Kind::Space);
        json!({
            "id": id,
            "kind": kind.name(),
            "url": self.page_url(kind, &id),
            "sourceID": row.get::<_, String>("source_id"),
            "title": row.get::<_, String>("title"),
            "excerpt": row.get::<_, Option<String>>("excerpt"),
            "itemCount": row.get::<_, i32>("item_count"),
            "createdAt": js_iso(row.get("created_at")),
            "updatedAt": js_iso(row.get("updated_at")),
        })
    }
}

fn not_found() -> ApiError {
    ApiError::status(404, "Share not found")
}

pub fn is_share_id(id: &str) -> bool {
    id.len() == ID_LENGTH && id.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

/// Ten characters of 62, drawn without bias.
fn random_id() -> anyhow::Result<String> {
    let mut id = String::with_capacity(ID_LENGTH);
    while id.len() < ID_LENGTH {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("random source failed: {error}"))?;
        for byte in bytes {
            // 248 is the largest multiple of 62 a byte holds.
            if byte < 248 && id.len() < ID_LENGTH {
                id.push(ID_ALPHABET[usize::from(byte % 62)] as char);
            }
        }
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_ten_alphanumerics() {
        let id = random_id().unwrap();
        assert!(is_share_id(&id), "{id}");
        assert_ne!(random_id().unwrap(), id);
        assert!(!is_share_id("short"));
        assert!(!is_share_id("abcdefghi-"));
        assert!(!is_share_id("abcdefghijk"));
    }
}
