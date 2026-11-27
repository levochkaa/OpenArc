//! Account deletion, and the Sign in with Apple tokens it revokes.
//!
//! Deleting an account removes the user row; every table that holds the
//! account's data references it with `ON DELETE CASCADE`, so one statement
//! removes devices, sync events, tombstones, receipts, Spaces, tabs, folders,
//! boosts, mobile tabs, identities and pending web sign-ins together. Email
//! codes are keyed by address and go separately.
//!
//! With a Sign in with Apple key configured, sign-in redeems Apple's
//! authorization code for a refresh token, and deletion revokes it at Apple.
//! A revocation that fails is kept and retried every hour for a week.

use crate::config::{AppleKey, Config};
use crate::error::{ApiError, ApiResult};
use deadpool_postgres::{Pool, Transaction};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const APPLE_AUDIENCE: &str = "https://appleid.apple.com";
/// A client secret is made for each request and lives this long.
const CLIENT_SECRET_SECONDS: u64 = 300;
const APPLE_TIMEOUT: Duration = Duration::from_secs(10);
/// Deletion requests per account in each window. Deletion is idempotent, so
/// this only stops a client from looping.
const DELETIONS_PER_WINDOW: usize = 5;
const DELETION_WINDOW: Duration = Duration::from_secs(15 * 60);

/// A refresh token Apple issued to one client ID.
#[derive(Clone, Debug, PartialEq)]
pub struct AppleGrant {
    pub client_id: String,
    pub refresh_token: String,
}

/// Apple's token and revocation endpoints, signed with the configured key.
#[derive(Clone)]
pub struct AppleTokens {
    http: reqwest::Client,
    key: Option<AppleKey>,
    token_url: String,
    revoke_url: String,
}

#[derive(Serialize)]
struct ClientSecretClaims<'a> {
    iss: &'a str,
    iat: u64,
    exp: u64,
    aud: &'a str,
    sub: &'a str,
}

impl AppleTokens {
    pub fn new(config: &Config, http: reqwest::Client) -> Self {
        let endpoints = &config.sign_in.endpoints;
        Self {
            http,
            key: config.sign_in.apple_key.clone(),
            token_url: endpoints.apple_token.clone(),
            revoke_url: endpoints.apple_revoke.clone(),
        }
    }

    /// The JWT Apple takes as `client_secret` for this client ID.
    fn client_secret(&self, key: &AppleKey, client_id: &str) -> anyhow::Result<String> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let claims = ClientSecretClaims {
            iss: &key.team_id,
            iat: now,
            exp: now + CLIENT_SECRET_SECONDS,
            aud: APPLE_AUDIENCE,
            sub: client_id,
        };
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(key.key_id.clone());
        header.typ = None;
        Ok(encode(&header, &claims, &EncodingKey::from_ec_pem(key.private_key.as_bytes())?)?)
    }

    /// Redeems a sign-in's authorization code for a refresh token. None when
    /// no key is configured, there is no code, or Apple refuses; sign-in goes
    /// on without one.
    pub async fn redeem(
        &self,
        client_id: &str,
        code: Option<&str>,
        redirect_uri: Option<&str>,
        subject: &str,
    ) -> Option<AppleGrant> {
        let (key, code) = (self.key.as_ref()?, code.filter(|code| !code.is_empty())?);
        match self.try_redeem(key, client_id, code, redirect_uri, subject).await {
            Ok(grant) => Some(grant),
            Err(error) => {
                tracing::warn!(error = format!("{error:#}"), "Apple authorization code was not redeemed");
                None
            }
        }
    }

    async fn try_redeem(
        &self,
        key: &AppleKey,
        client_id: &str,
        code: &str,
        redirect_uri: Option<&str>,
        subject: &str,
    ) -> anyhow::Result<AppleGrant> {
        let secret = self.client_secret(key, client_id)?;
        let mut pairs = vec![
            ("client_id", client_id),
            ("client_secret", secret.as_str()),
            ("code", code),
            ("grant_type", "authorization_code"),
        ];
        if let Some(redirect_uri) = redirect_uri {
            pairs.push(("redirect_uri", redirect_uri));
        }
        let response: Value = self
            .http
            .post(&self.token_url)
            .timeout(APPLE_TIMEOUT)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(form(&pairs))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        // The identity token comes straight from Apple over TLS; it only has
        // to name the account that signed in.
        let id_token = response.get("id_token").and_then(Value::as_str);
        let token_subject = id_token
            .and_then(|token| crate::signin::jwt_claims(token).ok())
            .and_then(|claims| claims.get("sub").and_then(Value::as_str).map(str::to_string));
        anyhow::ensure!(token_subject.as_deref() == Some(subject), "Apple issued tokens for another account");
        let refresh_token = response
            .get("refresh_token")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())
            .ok_or_else(|| anyhow::anyhow!("Apple sent no refresh token"))?;
        Ok(AppleGrant { client_id: client_id.to_string(), refresh_token: refresh_token.to_string() })
    }

    /// Revokes a refresh token. A token Apple no longer knows, because the
    /// user removed the app in their Apple Account, counts as revoked.
    pub async fn revoke(&self, grant: &AppleGrant) -> anyhow::Result<()> {
        let key = self.key.as_ref().ok_or_else(|| anyhow::anyhow!("no Sign in with Apple key is configured"))?;
        let secret = self.client_secret(key, &grant.client_id)?;
        let response = self
            .http
            .post(&self.revoke_url)
            .timeout(APPLE_TIMEOUT)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(form(&[
                ("client_id", &grant.client_id),
                ("client_secret", &secret),
                ("token", &grant.refresh_token),
                ("token_type_hint", "refresh_token"),
            ]))
            .send()
            .await?;
        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if status == reqwest::StatusCode::BAD_REQUEST
            && body.get("error").and_then(Value::as_str) == Some("invalid_grant")
        {
            return Ok(());
        }
        anyhow::bail!("Apple refused the revocation with {status}: {body}")
    }
}

/// Keeps the refresh token of an Apple identity that just signed in.
pub async fn store_apple_grant(tx: &Transaction<'_>, subject: &str, grant: Option<&AppleGrant>) -> ApiResult<()> {
    let Some(grant) = grant else { return Ok(()) };
    tx.execute(
        "UPDATE auth_identities SET apple_refresh_token = $2, apple_client_id = $3
         WHERE provider = 'apple' AND subject = $1",
        &[&subject, &grant.refresh_token, &grant.client_id],
    )
    .await?;
    Ok(())
}

#[derive(Clone)]
pub struct AccountService {
    pool: Pool,
    apple: AppleTokens,
    deletions: Arc<Mutex<HashMap<Uuid, Vec<Instant>>>>,
}

impl AccountService {
    pub fn new(pool: Pool, apple: AppleTokens) -> Self {
        Self { pool, apple, deletions: Arc::default() }
    }

    /// Deletes the account and everything stored for it. An account that is
    /// already gone succeeds again, so a client can retry after a lost reply.
    pub async fn delete(&self, user_id: Uuid) -> ApiResult<()> {
        self.count_deletion(user_id)?;
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        // The row lock waits for a push in progress, which takes it first.
        let Some(user) = tx.query_opt("SELECT email FROM app_users WHERE id = $1 FOR UPDATE", &[&user_id]).await?
        else {
            tx.commit().await?;
            return Ok(());
        };
        let mut emails: Vec<String> = user.get::<_, Option<String>>("email").into_iter().collect();
        let mut revocations = Vec::new();
        for identity in tx
            .query(
                "SELECT provider, subject, email, apple_refresh_token, apple_client_id
                 FROM auth_identities WHERE user_id = $1",
                &[&user_id],
            )
            .await?
        {
            emails.extend(identity.get::<_, Option<String>>("email"));
            if identity.get::<_, &str>("provider") == "email" {
                emails.push(identity.get("subject"));
            }
            let token: Option<String> = identity.get("apple_refresh_token");
            let client_id: Option<String> = identity.get("apple_client_id");
            if let (Some(refresh_token), Some(client_id)) = (token, client_id) {
                let id: Uuid = tx
                    .query_one(
                        "INSERT INTO apple_token_revocations (client_id, refresh_token) VALUES ($1, $2) RETURNING id",
                        &[&client_id, &refresh_token],
                    )
                    .await?
                    .get("id");
                revocations.push(id);
            }
        }
        let emails: Vec<String> = emails.iter().map(|email| email.to_lowercase()).collect();
        tx.execute("DELETE FROM auth_email_codes WHERE email = ANY($1)", &[&emails]).await?;
        tx.execute("DELETE FROM app_users WHERE id = $1", &[&user_id]).await?;
        tx.commit().await?;
        tracing::info!(user = %user_id, revocations = revocations.len(), "account deleted");
        if !revocations.is_empty()
            && let Err(error) = self.revoke_pending(Some(&revocations)).await
        {
            tracing::warn!(error = format!("{error:#}"), "Apple token revocation will be retried");
        }
        Ok(())
    }

    /// At most `DELETIONS_PER_WINDOW` requests per account in a window.
    fn count_deletion(&self, user_id: Uuid) -> ApiResult<()> {
        let now = Instant::now();
        let mut deletions = self.deletions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        deletions.retain(|_, times| {
            times.retain(|time| now.duration_since(*time) < DELETION_WINDOW);
            !times.is_empty()
        });
        let times = deletions.entry(user_id).or_default();
        if times.len() >= DELETIONS_PER_WINDOW {
            return Err(ApiError::status(429, "Too many requests; try again later"));
        }
        times.push(now);
        Ok(())
    }

    /// Sends pending revocations to Apple: these, or all of them. Accepted
    /// ones and ones older than a week are removed.
    pub async fn revoke_pending(&self, only: Option<&[Uuid]>) -> anyhow::Result<()> {
        let client = self.pool.get().await?;
        let expired = client
            .execute("DELETE FROM apple_token_revocations WHERE created_at < now() - interval '7 days'", &[])
            .await?;
        if expired > 0 {
            tracing::warn!(expired, "Apple token revocations gave up after a week");
        }
        let rows = match only {
            Some(ids) => {
                client
                    .query(
                        "SELECT id, client_id, refresh_token FROM apple_token_revocations WHERE id = ANY($1)",
                        &[&ids],
                    )
                    .await?
            }
            None => client.query("SELECT id, client_id, refresh_token FROM apple_token_revocations", &[]).await?,
        };
        let mut failed = None;
        for row in rows {
            let id: Uuid = row.get("id");
            let grant = AppleGrant { client_id: row.get("client_id"), refresh_token: row.get("refresh_token") };
            match self.apple.revoke(&grant).await {
                Ok(()) => {
                    client.execute("DELETE FROM apple_token_revocations WHERE id = $1", &[&id]).await?;
                }
                Err(error) => {
                    client
                        .execute("UPDATE apple_token_revocations SET attempts = attempts + 1 WHERE id = $1", &[&id])
                        .await?;
                    failed = Some(error);
                }
            }
        }
        failed.map_or(Ok(()), Err)
    }

    /// Retries failed revocations at start and every hour after.
    pub async fn revoke_pending_periodically(self) {
        let mut interval = tokio::time::interval(Duration::from_secs(3600));
        loop {
            interval.tick().await;
            if let Err(error) = self.revoke_pending(None).await {
                tracing::warn!(error = format!("{error:#}"), "Apple token revocation failed");
            }
        }
    }
}

fn form(pairs: &[(&str, &str)]) -> String {
    url::form_urlencoded::Serializer::new(String::new()).extend_pairs(pairs).finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{DecodingKey, Validation, decode, decode_header};
    use std::collections::HashMap as Map;

    /// A P-256 key in the `.p8` format Apple hands out, for tests only.
    const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgNYnsE8ZiU9qFIM2e
NufsxRfCMTvWRfg2QxCs1Zat0YyhRANCAAT/oC3cF5ML4BoMZs7iYa0uEOUZiMM5
FwEyvro9v7s1s8g11kNmxqfH5AkhRbofXj9CWRgGiF9McNgGqdE/u3yI
-----END PRIVATE KEY-----
";
    const TEST_PUBLIC_KEY: &str = "-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/6At3BeTC+AaDGbO4mGtLhDlGYjD
ORcBMr66Pb+7NbPINdZDZsanx+QJIUW6H14/QlkYBohfTHDYBqnRP7t8iA==
-----END PUBLIC KEY-----
";

    fn config(pairs: &[(&str, &str)]) -> Result<Config, String> {
        let mut environment: Map<String, String> = Map::from([
            ("DATABASE_URL".to_string(), "postgres://test@127.0.0.1/test".to_string()),
            ("JWT_SECRET".to_string(), "test-secret-with-at-least-thirty-two-bytes".to_string()),
            ("APPLE_CLIENT_ID".to_string(), "com.openarc.test".to_string()),
        ]);
        for (key, value) in pairs {
            environment.insert((*key).to_string(), (*value).to_string());
        }
        Config::parse(&environment)
    }

    #[test]
    fn client_secrets_are_es256_jwts_for_apple() {
        let one_line = TEST_KEY.replace('\n', "\\n");
        let config = config(&[
            ("OPENARC_APPLE_TEAM_ID", "TEAM123456"),
            ("OPENARC_APPLE_KEY_ID", "KEY1234567"),
            ("OPENARC_APPLE_PRIVATE_KEY", &one_line),
        ])
        .unwrap();
        let tokens = AppleTokens::new(&config, reqwest::Client::new());
        let key = config.sign_in.apple_key.as_ref().unwrap();
        let secret = tokens.client_secret(key, "com.openarc.test").unwrap();
        let header = decode_header(&secret).unwrap();
        assert_eq!(header.alg, Algorithm::ES256);
        assert_eq!(header.kid.as_deref(), Some("KEY1234567"));
        let mut validation = Validation::new(Algorithm::ES256);
        validation.set_audience(&[APPLE_AUDIENCE]);
        validation.set_issuer(&["TEAM123456"]);
        let claims =
            decode::<Value>(&secret, &DecodingKey::from_ec_pem(TEST_PUBLIC_KEY.as_bytes()).unwrap(), &validation)
                .unwrap()
                .claims;
        assert_eq!(claims["sub"], "com.openarc.test");
        let lifetime = claims["exp"].as_u64().unwrap() - claims["iat"].as_u64().unwrap();
        assert_eq!(lifetime, CLIENT_SECRET_SECONDS);
    }

    #[test]
    fn the_apple_key_needs_all_three_settings_and_a_valid_pem() {
        assert_eq!(config(&[]).unwrap().sign_in.apple_key, None);
        assert!(config(&[("OPENARC_APPLE_TEAM_ID", "TEAM123456")]).is_err());
        assert!(
            config(&[
                ("OPENARC_APPLE_TEAM_ID", "TEAM123456"),
                ("OPENARC_APPLE_KEY_ID", "KEY1234567"),
                ("OPENARC_APPLE_PRIVATE_KEY", "not a key"),
            ])
            .is_err()
        );
        let debug = format!(
            "{:?}",
            config(&[
                ("OPENARC_APPLE_TEAM_ID", "TEAM123456"),
                ("OPENARC_APPLE_KEY_ID", "KEY1234567"),
                ("OPENARC_APPLE_PRIVATE_KEY", TEST_KEY),
            ])
            .unwrap()
            .sign_in
            .apple_key
        );
        assert!(!debug.contains("PRIVATE KEY"), "logs never show the key: {debug}");
    }
}
