//! Sync access tokens (HS256 JWTs) and Apple identity token verification
//! against Apple's published keys.

use crate::config::Config;
use crate::error::{ApiError, ApiResult};
use jsonwebtoken::jwk::{Jwk, JwkSet};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, decode_header, encode};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

pub const APPLE_KEYS_URL: &str = "https://appleid.apple.com/auth/keys";
const APPLE_ISSUER: &str = "https://appleid.apple.com";
/// Thirty days, also returned to clients as `expiresIn`.
pub const ACCESS_TOKEN_SECONDS: u64 = 60 * 60 * 24 * 30;
const KEY_CACHE_AGE: Duration = Duration::from_secs(600);
const KEY_REFETCH_COOLDOWN: Duration = Duration::from_secs(30);
/// Callers wait on one fetch; a stalled Apple endpoint fails them after this.
const KEY_FETCH_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, PartialEq)]
pub struct AppleIdentity {
    pub apple_subject: String,
    pub email: Option<String>,
}

#[derive(Clone)]
pub struct AuthService {
    inner: Arc<Inner>,
}

struct Inner {
    secret: Vec<u8>,
    issuer: String,
    audience: String,
    apple_client_ids: Vec<String>,
    apple_keys_url: String,
    http: reqwest::Client,
    apple_keys: Mutex<Option<(Instant, JwkSet)>>,
}

#[derive(Serialize, Deserialize)]
struct AccessClaims {
    sub: String,
    iss: String,
    aud: String,
    iat: u64,
    exp: u64,
}

#[derive(Deserialize)]
struct SubjectClaims {
    sub: Option<String>,
    exp: Option<u64>,
}

#[derive(Deserialize)]
struct AppleClaims {
    sub: Option<String>,
    exp: Option<u64>,
    email: Option<serde_json::Value>,
}

impl AuthService {
    pub fn new(config: &Config, http: reqwest::Client) -> Self {
        Self::with_apple_keys_url(config, http, APPLE_KEYS_URL)
    }

    /// Tests serve their own keys; production always uses Apple's.
    pub fn with_apple_keys_url(config: &Config, http: reqwest::Client, apple_keys_url: &str) -> Self {
        Self {
            inner: Arc::new(Inner {
                secret: config.jwt_secret.as_bytes().to_vec(),
                issuer: config.jwt_issuer.clone(),
                audience: config.jwt_audience.clone(),
                apple_client_ids: config.apple_client_ids.clone(),
                apple_keys_url: apple_keys_url.to_string(),
                http,
                apple_keys: Mutex::new(None),
            }),
        }
    }

    pub fn issue_access_token(&self, user_id: &str) -> anyhow::Result<String> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let claims = AccessClaims {
            sub: user_id.to_string(),
            iss: self.inner.issuer.clone(),
            aud: self.inner.audience.clone(),
            iat: now,
            exp: now + ACCESS_TOKEN_SECONDS,
        };
        let mut header = Header::new(Algorithm::HS256);
        header.typ = None;
        Ok(encode(&header, &claims, &EncodingKey::from_secret(&self.inner.secret))?)
    }

    /// The user ID of a valid access token.
    pub fn verify_access_token(&self, token: &str) -> anyhow::Result<String> {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.algorithms = vec![Algorithm::HS256, Algorithm::HS384, Algorithm::HS512];
        validation.leeway = 0;
        validation.validate_nbf = true;
        validation.required_spec_claims = ["iss", "aud"].into_iter().map(str::to_string).collect();
        validation.set_issuer(&[&self.inner.issuer]);
        validation.set_audience(&[&self.inner.audience]);
        let claims = decode::<SubjectClaims>(token, &DecodingKey::from_secret(&self.inner.secret), &validation)?.claims;
        expired_at_now(claims.exp)?;
        claims.sub.filter(|sub| !sub.is_empty()).ok_or_else(|| anyhow::anyhow!("Access token has no subject"))
    }

    pub fn user_id_from_authorization(&self, header: Option<&str>) -> ApiResult<String> {
        let token = header.and_then(|value| value.strip_prefix("Bearer ")).ok_or(ApiError::Unauthorized)?;
        self.verify_access_token(token).map_err(|_| ApiError::Unauthorized)
    }

    /// Verifies signature, issuer, audience and lifetime. A token that fails
    /// is a server error, as it was before the Rust rewrite.
    pub async fn verify_apple_identity_token(&self, token: &str) -> ApiResult<AppleIdentity> {
        let header = decode_header(token).map_err(|error| ApiError::Internal(error.into()))?;
        let jwk = self.apple_key(header.kid.as_deref()).await?;
        let algorithm =
            match jwk.common.key_algorithm.and_then(|algorithm| algorithm.to_string().parse::<Algorithm>().ok()) {
                Some(algorithm) => algorithm,
                None => header.alg,
            };
        if algorithm != header.alg
            || !matches!(
                algorithm,
                Algorithm::RS256
                    | Algorithm::RS384
                    | Algorithm::RS512
                    | Algorithm::ES256
                    | Algorithm::ES384
                    | Algorithm::PS256
                    | Algorithm::PS384
                    | Algorithm::PS512
            )
        {
            return Err(ApiError::Internal(anyhow::anyhow!("Apple identity token uses an unexpected algorithm")));
        }
        let mut validation = Validation::new(algorithm);
        validation.leeway = 0;
        validation.validate_nbf = true;
        validation.required_spec_claims = ["iss", "aud"].into_iter().map(str::to_string).collect();
        validation.set_issuer(&[APPLE_ISSUER]);
        validation.set_audience(&self.inner.apple_client_ids);
        let key = DecodingKey::from_jwk(&jwk).map_err(|error| ApiError::Internal(error.into()))?;
        let claims =
            decode::<AppleClaims>(token, &key, &validation).map_err(|error| ApiError::Internal(error.into()))?.claims;
        expired_at_now(claims.exp).map_err(ApiError::Internal)?;
        let apple_subject = claims
            .sub
            .filter(|sub| !sub.is_empty())
            .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("Apple identity token has no subject")))?;
        let email = match claims.email {
            Some(serde_json::Value::String(email)) => {
                if !is_email(&email) {
                    return Err(ApiError::Internal(anyhow::anyhow!("Apple identity token has an invalid email")));
                }
                Some(email)
            }
            _ => None,
        };
        Ok(AppleIdentity { apple_subject, email })
    }

    /// The key with this ID from a cached key set, refetched when it is old
    /// or misses the key (at most once per cooldown).
    async fn apple_key(&self, kid: Option<&str>) -> ApiResult<Jwk> {
        let mut cache = self.inner.apple_keys.lock().await;
        let find = |set: &JwkSet| match kid {
            Some(kid) => set.find(kid).cloned(),
            None if set.keys.len() == 1 => set.keys.first().cloned(),
            None => None,
        };
        if let Some((fetched, set)) = cache.as_ref()
            && fetched.elapsed() < KEY_CACHE_AGE
        {
            if let Some(key) = find(set) {
                return Ok(key);
            }
            if fetched.elapsed() < KEY_REFETCH_COOLDOWN {
                return Err(ApiError::Internal(anyhow::anyhow!("no Apple key matches the token")));
            }
        }
        let set: JwkSet = self
            .inner
            .http
            .get(&self.inner.apple_keys_url)
            .timeout(KEY_FETCH_TIMEOUT)
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
            .map_err(|error| ApiError::Internal(error.into()))?
            .json()
            .await
            .map_err(|error| ApiError::Internal(error.into()))?;
        let key = find(&set);
        *cache = Some((Instant::now(), set));
        key.ok_or_else(|| ApiError::Internal(anyhow::anyhow!("no Apple key matches the token")))
    }
}

/// A token that expires this second is already expired, as `jose` decides.
fn expired_at_now(exp: Option<u64>) -> anyhow::Result<()> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    if exp.is_some_and(|exp| exp <= now) {
        anyhow::bail!("token expired");
    }
    Ok(())
}

/// Zod's practical email check.
fn is_email(email: &str) -> bool {
    static EMAIL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^([A-Za-z0-9_'+\-.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$")
            .expect("valid regex")
    });
    !email.starts_with('.') && !email.contains("..") && EMAIL.is_match(email)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn config() -> Config {
        Config::parse(&HashMap::from([
            ("DATABASE_URL".to_string(), "postgres://test@127.0.0.1/test".to_string()),
            ("JWT_SECRET".to_string(), "test-secret-with-at-least-thirty-two-bytes".to_string()),
            ("APPLE_CLIENT_IDS".to_string(), "com.openarc.desktop,com.openarc.mobile".to_string()),
        ]))
        .unwrap()
    }

    #[test]
    fn access_tokens_round_trip_and_reject_other_audiences_and_garbage() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let auth = AuthService::new(&config(), reqwest::Client::new());
        let token = auth.issue_access_token("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(auth.verify_access_token(&token).unwrap(), "550e8400-e29b-41d4-a716-446655440000");
        assert!(auth.user_id_from_authorization(Some(&format!("bearer {token}"))).is_err());
        assert!(auth.user_id_from_authorization(Some("Bearer invalid-token")).is_err());
        assert!(auth.user_id_from_authorization(None).is_err());
        let mut other = config();
        other.jwt_audience = "someone-else".to_string();
        let foreign = AuthService::new(&other, reqwest::Client::new()).issue_access_token("x").unwrap();
        assert!(auth.verify_access_token(&foreign).is_err());

        // Not yet valid, and expiring this second, are both refused.
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let key = EncodingKey::from_secret(b"test-secret-with-at-least-thirty-two-bytes");
        let sign = |claims: serde_json::Value| encode(&Header::new(Algorithm::HS256), &claims, &key).unwrap();
        let base = serde_json::json!({"sub": "u", "iss": "openarc-sync", "aud": "openarc-clients", "iat": now});
        let mut future = base.clone();
        future["nbf"] = (now + 60).into();
        future["exp"] = (now + 120).into();
        assert!(auth.verify_access_token(&sign(future)).is_err());
        let mut expiring = base.clone();
        expiring["exp"] = now.into();
        assert!(auth.verify_access_token(&sign(expiring)).is_err());
        let mut valid = base;
        valid["exp"] = (now + 60).into();
        assert_eq!(auth.verify_access_token(&sign(valid)).unwrap(), "u");
    }

    #[test]
    fn email_check_follows_zod() {
        assert!(is_email("local@example.test"));
        assert!(is_email("a.b+c@sub.example.com"));
        assert!(!is_email(".a@example.com"));
        assert!(!is_email("a..b@example.com"));
        assert!(!is_email("a.@example.com"));
        assert!(!is_email("a@example"));
    }
}
