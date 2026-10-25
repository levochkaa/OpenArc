//! Sign-in methods besides native Sign in with Apple: Sign in with Apple,
//! Google and GitHub on the web, and codes sent by email. Every method ends in
//! an identity of one account; a new identity with a verified email joins the
//! account that already has that email.
//!
//! A web sign-in runs in the app's web authentication session: start stores a
//! pending sign-in with the app's PKCE challenge and redirects to the
//! provider, the provider's callback resolves the account and redirects to
//! the app with a single-use code, and the app redeems the code with its
//! verifier.

use crate::auth::{ACCESS_TOKEN_SECONDS, AuthService, is_email};
use crate::config::{Config, OAuthClient};
use crate::error::{ApiError, ApiResult};
use crate::sync::serialize_device;
use anyhow::Context;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use deadpool_postgres::{Pool, Transaction};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Where web sign-in returns to the app.
pub const APP_CALLBACK: &str = "openarc-auth://callback";
/// The user has this long at the provider.
const SIGN_IN_SECONDS: f64 = 600.0;
/// The app has this long to redeem its code.
const CODE_SECONDS: f64 = 300.0;
pub const EMAIL_CODE_SECONDS: i64 = 600;
pub const EMAIL_RESEND_SECONDS: i64 = 60;
const EMAIL_SENDS_PER_HOUR: i32 = 5;
const EMAIL_ATTEMPTS: i32 = 5;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum WebProvider {
    Apple,
    Google,
    Github,
}

impl WebProvider {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "apple" => Some(Self::Apple),
            "google" => Some(Self::Google),
            "github" => Some(Self::Github),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Apple => "apple",
            Self::Google => "google",
            Self::Github => "github",
        }
    }
}

/// An account's way to sign in: a provider and its stable subject.
#[derive(Clone, Debug, PartialEq)]
pub struct Identity {
    pub provider: &'static str,
    pub subject: String,
    pub email: Option<String>,
    pub email_verified: bool,
}

/// Why a web sign-in returned to the app without a code.
#[derive(Clone, Copy, Debug, PartialEq)]
enum WebFailure {
    AccessDenied,
    Expired,
    ProviderError,
}

impl WebFailure {
    fn reason(self) -> &'static str {
        match self {
            Self::AccessDenied => "access_denied",
            Self::Expired => "expired",
            Self::ProviderError => "provider_error",
        }
    }
}

#[derive(Clone)]
pub struct SignInService {
    pool: Pool,
    auth: AuthService,
    config: Arc<Config>,
    http: reqwest::Client,
}

impl SignInService {
    pub fn new(pool: Pool, auth: AuthService, config: Arc<Config>, http: reqwest::Client) -> Self {
        Self { pool, auth, config, http }
    }

    pub fn providers(&self) -> Value {
        let mut providers = vec!["apple"];
        if self.is_configured(WebProvider::Google) {
            providers.push("google");
        }
        if self.is_configured(WebProvider::Github) {
            providers.push("github");
        }
        if self.config.sign_in.resend_api_key.is_some() {
            providers.push("email");
        }
        // Native Sign in with Apple needs no web configuration; the web flow,
        // which macOS uses, does.
        if !self.is_configured(WebProvider::Apple) {
            providers.retain(|provider| *provider != "apple");
        }
        json!({"providers": providers})
    }

    fn is_configured(&self, provider: WebProvider) -> bool {
        let sign_in = &self.config.sign_in;
        self.config.public_base_url.is_some()
            && match provider {
                WebProvider::Apple => sign_in.apple_services_id.is_some(),
                WebProvider::Google => sign_in.google.is_some(),
                WebProvider::Github => sign_in.github.is_some(),
            }
    }

    // MARK: Web sign-in

    /// The provider's sign-in page for a new web sign-in.
    pub async fn start_web(&self, provider: &str, code_challenge: Option<&str>) -> ApiResult<String> {
        let provider = WebProvider::parse(provider)
            .filter(|provider| self.is_configured(*provider))
            .ok_or_else(|| ApiError::status(404, "This sign-in method is not available"))?;
        let challenge = code_challenge
            .filter(|challenge| is_code_challenge(challenge))
            .ok_or_else(|| ApiError::BadRequest("code_challenge must be a base64url SHA-256 digest".to_string()))?;
        let state = random_token()?;
        let nonce = random_token()?;
        let url = self.authorize_url(provider, &state, &nonce)?;
        let client = self.pool.get().await?;
        client
            .execute(
                "INSERT INTO auth_web_sign_ins (provider, state_hash, nonce, code_challenge, expires_at)
                 VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5))",
                &[&provider.name(), &digest(&state), &nonce, &challenge, &SIGN_IN_SECONDS],
            )
            .await?;
        Ok(url)
    }

    fn redirect_uri(&self, provider: WebProvider) -> String {
        let base = self.config.public_base_url.as_deref().unwrap_or_default().trim_end_matches('/');
        format!("{base}/v1/auth/{}/callback", provider.name())
    }

    fn authorize_url(&self, provider: WebProvider, state: &str, nonce: &str) -> ApiResult<String> {
        let sign_in = &self.config.sign_in;
        let redirect_uri = self.redirect_uri(provider);
        let (base, pairs): (&str, Vec<(&str, &str)>) = match provider {
            WebProvider::Apple => (
                &sign_in.endpoints.apple_authorize,
                vec![
                    ("client_id", sign_in.apple_services_id.as_deref().unwrap_or_default()),
                    ("redirect_uri", &redirect_uri),
                    ("response_type", "code id_token"),
                    // Apple sends the name and email only in a form post.
                    ("response_mode", "form_post"),
                    ("scope", "name email"),
                    ("state", state),
                    ("nonce", nonce),
                ],
            ),
            WebProvider::Google => (
                &sign_in.endpoints.google_authorize,
                vec![
                    ("client_id", sign_in.google.as_ref().map_or("", |client| client.id.as_str())),
                    ("redirect_uri", &redirect_uri),
                    ("response_type", "code"),
                    ("scope", "openid email profile"),
                    ("state", state),
                    ("nonce", nonce),
                    ("prompt", "select_account"),
                ],
            ),
            WebProvider::Github => (
                &sign_in.endpoints.github_authorize,
                vec![
                    ("client_id", sign_in.github.as_ref().map_or("", |client| client.id.as_str())),
                    ("redirect_uri", &redirect_uri),
                    ("scope", "read:user user:email"),
                    ("state", state),
                ],
            ),
        };
        let mut url = url::Url::parse(base).context("invalid provider authorize URL")?;
        url.query_pairs_mut().extend_pairs(pairs);
        Ok(url.to_string())
    }

    /// Finishes the provider round trip: the app callback with a code, or
    /// with the reason there is none.
    pub async fn finish_web(&self, provider: WebProvider, params: &HashMap<String, String>) -> String {
        match self.try_finish_web(provider, params).await {
            Ok(code) => app_callback("code", &code),
            Err(failure) => app_callback("error", failure.reason()),
        }
    }

    async fn try_finish_web(
        &self,
        provider: WebProvider,
        params: &HashMap<String, String>,
    ) -> Result<String, WebFailure> {
        if params.contains_key("error") {
            return Err(WebFailure::AccessDenied);
        }
        let state = params.get("state").ok_or(WebFailure::Expired)?;
        let pending = self
            .pool
            .get()
            .await
            .map_err(|error| provider_failure(provider, error.into()))?
            .query_opt(
                "SELECT id, nonce FROM auth_web_sign_ins
                 WHERE state_hash = $1 AND provider = $2 AND expires_at > now() AND code_hash IS NULL",
                &[&digest(state), &provider.name()],
            )
            .await
            .map_err(|error| provider_failure(provider, error.into()))?
            .ok_or(WebFailure::Expired)?;
        let id: Uuid = pending.get("id");
        let nonce: String = pending.get("nonce");
        let identity = match provider {
            WebProvider::Apple => self.apple_identity(params, &nonce).await,
            WebProvider::Google => self.google_identity(params.get("code"), &nonce).await,
            WebProvider::Github => self.github_identity(params.get("code")).await,
        }
        .map_err(|error| provider_failure(provider, error))?;
        let code = random_token().map_err(|error| provider_failure(provider, error))?;
        self.issue_web_code(id, &identity, &code).await.map_err(|error| match error {
            ApiError::Status(..) => WebFailure::Expired,
            error => provider_failure(provider, anyhow::anyhow!("{error:?}")),
        })?;
        Ok(code)
    }

    async fn issue_web_code(&self, id: Uuid, identity: &Identity, code: &str) -> ApiResult<()> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let user_id = resolve_user(&tx, identity).await?;
        let updated = tx
            .execute(
                "UPDATE auth_web_sign_ins
                 SET code_hash = $2, user_id = $3, code_expires_at = now() + make_interval(secs => $4)
                 WHERE id = $1 AND code_hash IS NULL AND expires_at > now()",
                &[&id, &digest(code), &user_id, &CODE_SECONDS],
            )
            .await?;
        if updated != 1 {
            return Err(ApiError::status(410, "The sign-in was already finished"));
        }
        tx.commit().await?;
        Ok(())
    }

    async fn apple_identity(&self, params: &HashMap<String, String>, nonce: &str) -> anyhow::Result<Identity> {
        let token = params.get("id_token").context("Apple sent no identity token")?;
        let services_id = self.config.sign_in.apple_services_id.as_deref().context("Apple is not configured")?;
        let apple = self
            .auth
            .verify_apple_web_token(token, services_id)
            .await
            .map_err(|error| anyhow::anyhow!("Apple identity token rejected: {error:?}"))?;
        anyhow::ensure!(apple.nonce.as_deref() == Some(nonce), "Apple identity token has another nonce");
        Ok(Identity {
            provider: "apple",
            subject: apple.apple_subject,
            email: apple.email,
            email_verified: apple.email_verified,
        })
    }

    async fn google_identity(&self, code: Option<&String>, nonce: &str) -> anyhow::Result<Identity> {
        let client = self.config.sign_in.google.as_ref().context("Google is not configured")?;
        let code = code.context("Google sent no code")?;
        let redirect_uri = self.redirect_uri(WebProvider::Google);
        let response: Value = self
            .http
            .post(&self.config.sign_in.endpoints.google_token)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(form(&[
                ("code", code),
                ("client_id", &client.id),
                ("client_secret", &client.secret),
                ("redirect_uri", &redirect_uri),
                ("grant_type", "authorization_code"),
            ]))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let token = response.get("id_token").and_then(Value::as_str).context("Google sent no identity token")?;
        google_identity_from_token(token, client, nonce)
    }

    async fn github_identity(&self, code: Option<&String>) -> anyhow::Result<Identity> {
        let client = self.config.sign_in.github.as_ref().context("GitHub is not configured")?;
        let code = code.context("GitHub sent no code")?;
        let endpoints = &self.config.sign_in.endpoints;
        let redirect_uri = self.redirect_uri(WebProvider::Github);
        let response: Value = self
            .http
            .post(&endpoints.github_token)
            .header("accept", "application/json")
            .header("content-type", "application/x-www-form-urlencoded")
            .body(form(&[
                ("client_id", &client.id),
                ("client_secret", &client.secret),
                ("code", code),
                ("redirect_uri", &redirect_uri),
            ]))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let access_token = response.get("access_token").and_then(Value::as_str).context("GitHub sent no token")?;
        let api = endpoints.github_api.trim_end_matches('/');
        let get = |path: String| {
            self.http
                .get(path)
                .bearer_auth(access_token)
                .header("accept", "application/vnd.github+json")
                .header("user-agent", "OpenArc")
        };
        let user: Value = get(format!("{api}/user")).send().await?.error_for_status()?.json().await?;
        let emails: Value = get(format!("{api}/user/emails")).send().await?.error_for_status()?.json().await?;
        let id = user.get("id").and_then(Value::as_i64).context("GitHub user has no ID")?;
        let email = github_verified_email(&emails);
        Ok(Identity { provider: "github", subject: id.to_string(), email_verified: email.is_some(), email })
    }

    /// Redeems a web sign-in code. A wrong verifier leaves the code unused.
    pub async fn exchange_web(&self, body: &Value) -> ApiResult<Value> {
        let code = text(body, "code");
        let verifier = text(body, "codeVerifier");
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let row = tx
            .query_opt(
                "UPDATE auth_web_sign_ins SET redeemed_at = now()
                 WHERE code_hash = $1 AND redeemed_at IS NULL AND code_expires_at > now()
                 RETURNING user_id, code_challenge",
                &[&digest(code)],
            )
            .await?
            .ok_or_else(|| ApiError::status(401, "The sign-in code is invalid or expired"))?;
        let challenge: String = row.get("code_challenge");
        if !constant_time_eq(code_challenge(verifier).as_bytes(), challenge.as_bytes()) {
            return Err(ApiError::status(401, "The sign-in code is invalid or expired"));
        }
        let user_id: Uuid = row.get("user_id");
        let session =
            create_session(&tx, &self.auth, user_id, text(body, "deviceName"), text(body, "devicePlatform")).await?;
        tx.commit().await?;
        Ok(session)
    }

    // MARK: Email codes

    /// Emails a six-digit code, unless one went out too recently.
    pub async fn start_email(&self, body: &Value) -> ApiResult<Value> {
        let api_key = self
            .config
            .sign_in
            .resend_api_key
            .as_deref()
            .ok_or_else(|| ApiError::status(503, "Email sign-in is not configured"))?;
        let email =
            normalized_email(text(body, "email")).ok_or_else(|| ApiError::BadRequest("Invalid email".to_string()))?;
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let previous = tx
            .query_opt(
                "SELECT sent_at > now() - make_interval(secs => $2) AS too_soon,
                        window_started_at > now() - interval '1 hour' AS in_window,
                        sends_in_window
                 FROM auth_email_codes WHERE email = $1 FOR UPDATE",
                &[&email, &(EMAIL_RESEND_SECONDS as f64)],
            )
            .await?;
        let in_window = match &previous {
            Some(row) if row.get::<_, bool>("too_soon") => {
                return Err(ApiError::status(429, "Wait a minute before asking for another code"));
            }
            Some(row) if row.get::<_, bool>("in_window") => {
                if row.get::<_, i32>("sends_in_window") >= EMAIL_SENDS_PER_HOUR {
                    return Err(ApiError::status(429, "Too many codes for this email; try again later"));
                }
                true
            }
            _ => false,
        };
        let code = six_digit_code()?;
        tx.execute(
            "INSERT INTO auth_email_codes (email, code_hash, sent_at, expires_at, window_started_at)
             VALUES ($1, $2, now(), now() + make_interval(secs => $3), now())
             ON CONFLICT (email) DO UPDATE SET
               code_hash = EXCLUDED.code_hash,
               attempts = 0,
               sent_at = now(),
               expires_at = EXCLUDED.expires_at,
               window_started_at = CASE WHEN $4 THEN auth_email_codes.window_started_at ELSE now() END,
               sends_in_window = CASE WHEN $4 THEN auth_email_codes.sends_in_window + 1 ELSE 1 END",
            &[&email, &self.email_code_hash(&email, &code), &(EMAIL_CODE_SECONDS as f64), &in_window],
        )
        .await?;
        // Sent before committing, so a failed send can be retried at once.
        self.send_code(api_key, &email, &code).await.map_err(|error| {
            tracing::warn!(error = format!("{error:#}"), "sign-in email failed");
            ApiError::status(502, "The email could not be sent")
        })?;
        tx.commit().await?;
        Ok(json!({"expiresIn": EMAIL_CODE_SECONDS, "resendIn": EMAIL_RESEND_SECONDS}))
    }

    async fn send_code(&self, api_key: &str, email: &str, code: &str) -> anyhow::Result<()> {
        let minutes = EMAIL_CODE_SECONDS / 60;
        self.http
            .post(&self.config.sign_in.endpoints.resend_emails)
            .bearer_auth(api_key)
            .json(&json!({
                "from": self.config.sign_in.email_from,
                "to": [email],
                "subject": format!("{code} is your OpenArc code"),
                "text": format!(
                    "Your OpenArc sign-in code is {code}. It expires in {minutes} minutes.\n\n\
                     If you did not try to sign in, you can ignore this email."
                ),
            }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    /// Signs in with an emailed code. Wrong codes count toward a limit that
    /// ends the code.
    pub async fn verify_email(&self, body: &Value) -> ApiResult<Value> {
        let email =
            normalized_email(text(body, "email")).ok_or_else(|| ApiError::BadRequest("Invalid email".to_string()))?;
        let code = text(body, "code");
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let row = tx
            .query_opt(
                "SELECT code_hash, attempts, expires_at > now() AS live
                 FROM auth_email_codes WHERE email = $1 FOR UPDATE",
                &[&email],
            )
            .await?;
        let Some(row) = row.filter(|row| row.get::<_, bool>("live") && row.get::<_, i32>("attempts") < EMAIL_ATTEMPTS)
        else {
            return Err(ApiError::status(401, "The code expired; ask for a new one"));
        };
        let stored: String = row.get("code_hash");
        if !constant_time_eq(self.email_code_hash(&email, code).as_bytes(), stored.as_bytes()) {
            tx.execute("UPDATE auth_email_codes SET attempts = attempts + 1 WHERE email = $1", &[&email]).await?;
            tx.commit().await?;
            return Err(ApiError::status(401, "Wrong code"));
        }
        tx.execute("DELETE FROM auth_email_codes WHERE email = $1", &[&email]).await?;
        let identity = Identity { provider: "email", subject: email.clone(), email: Some(email), email_verified: true };
        let user_id = resolve_user(&tx, &identity).await?;
        let session =
            create_session(&tx, &self.auth, user_id, text(body, "deviceName"), text(body, "devicePlatform")).await?;
        tx.commit().await?;
        Ok(session)
    }

    /// Peppered with the server secret, so a database copy cannot try all
    /// million codes offline.
    fn email_code_hash(&self, email: &str, code: &str) -> String {
        digest(&format!("{}:{email}:{code}", self.config.jwt_secret))
    }
}

// MARK: Cleanup

/// Deletes finished and expired sign-in records every hour, so none outlives
/// its use by more than two hours.
pub async fn clean_up_periodically(pool: Pool) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(3600));
    loop {
        interval.tick().await;
        if let Err(error) = clean_up(&pool).await {
            tracing::warn!(error = format!("{error:#}"), "sign-in cleanup failed");
        }
    }
}

pub async fn clean_up(pool: &Pool) -> anyhow::Result<()> {
    pool.get()
        .await?
        .batch_execute(
            "DELETE FROM auth_web_sign_ins
             WHERE expires_at < now() - interval '1 hour'
               AND (code_expires_at IS NULL OR code_expires_at < now() - interval '1 hour');
             DELETE FROM auth_email_codes
             WHERE expires_at < now() AND window_started_at < now() - interval '1 hour';",
        )
        .await?;
    Ok(())
}

// MARK: Accounts and sessions

/// The account of an identity: its own, the account that already has its
/// verified email, or a new one. Locks keep concurrent first sign-ins of one
/// identity or email from creating two accounts.
pub async fn resolve_user(tx: &Transaction<'_>, identity: &Identity) -> ApiResult<Uuid> {
    let email = identity.email.as_deref();
    tx.execute(
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        &[&format!("identity:{}:{}", identity.provider, identity.subject)],
    )
    .await?;
    let existing = tx
        .query_opt(
            "UPDATE auth_identities
             SET email = COALESCE($3, email), email_verified = email_verified OR $4, updated_at = now()
             WHERE provider = $1 AND subject = $2
             RETURNING user_id",
            &[&identity.provider, &identity.subject, &email, &identity.email_verified],
        )
        .await?;
    let user_id = match existing {
        Some(row) => row.get("user_id"),
        None => {
            // An Apple account a server before identities created.
            let mut linked = if identity.provider == "apple" {
                tx.query_opt("SELECT id FROM app_users WHERE apple_subject = $1", &[&identity.subject])
                    .await?
                    .map(|row| row.get::<_, Uuid>("id"))
            } else {
                None
            };
            if linked.is_none()
                && identity.email_verified
                && let Some(email) = email
            {
                tx.execute("SELECT pg_advisory_xact_lock(hashtext($1))", &[&format!("email:{}", email.to_lowercase())])
                    .await?;
                linked = tx
                    .query_opt(
                        "SELECT user_id FROM auth_identities
                         WHERE email_verified AND lower(email) = lower($1)
                         ORDER BY created_at LIMIT 1",
                        &[&email],
                    )
                    .await?
                    .map(|row| row.get::<_, Uuid>("user_id"));
            }
            let user_id = match linked {
                Some(user_id) => user_id,
                None => {
                    tx.query_one("INSERT INTO app_users (email) VALUES ($1) RETURNING id", &[&email]).await?.get("id")
                }
            };
            tx.execute(
                "INSERT INTO auth_identities (provider, subject, user_id, email, email_verified)
                 VALUES ($1, $2, $3, $4, $5)",
                &[&identity.provider, &identity.subject, &user_id, &email, &identity.email_verified],
            )
            .await?;
            user_id
        }
    };
    tx.execute(
        "UPDATE app_users SET email = COALESCE(email, $2), updated_at = now() WHERE id = $1",
        &[&user_id, &email],
    )
    .await?;
    Ok(user_id)
}

/// A new device and access token, the response of every sign-in method.
pub async fn create_session(
    tx: &Transaction<'_>,
    auth: &AuthService,
    user_id: Uuid,
    device_name: &str,
    device_platform: &str,
) -> ApiResult<Value> {
    let device = tx
        .query_one(
            "INSERT INTO devices (user_id, name, platform)
             VALUES ($1, $2, $3)
             RETURNING id, name, platform, public_key, last_seen_at",
            &[&user_id, &device_name, &device_platform],
        )
        .await?;
    let email: Option<String> =
        tx.query_one("SELECT email FROM app_users WHERE id = $1", &[&user_id]).await?.get("email");
    Ok(json!({
        "accessToken": auth.issue_access_token(&user_id.to_string())?,
        "tokenType": "Bearer",
        "expiresIn": ACCESS_TOKEN_SECONDS,
        "user": {"id": user_id.to_string(), "email": email},
        "device": serialize_device(&device),
    }))
}

// MARK: Helpers

fn provider_failure(provider: WebProvider, error: anyhow::Error) -> WebFailure {
    tracing::warn!(provider = provider.name(), error = format!("{error:#}"), "web sign-in failed");
    WebFailure::ProviderError
}

fn app_callback(key: &str, value: &str) -> String {
    let mut url = url::Url::parse(APP_CALLBACK).expect("valid app callback");
    url.query_pairs_mut().append_pair(key, value);
    url.to_string()
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn form(pairs: &[(&str, &str)]) -> String {
    url::form_urlencoded::Serializer::new(String::new()).extend_pairs(pairs).finish()
}

fn digest(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// PKCE's S256 challenge of a verifier.
pub fn code_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn is_code_challenge(text: &str) -> bool {
    text.len() == 43 && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn random_bytes<const N: usize>() -> anyhow::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("random source failed: {error}"))?;
    Ok(bytes)
}

fn random_token() -> anyhow::Result<String> {
    Ok(URL_SAFE_NO_PAD.encode(random_bytes::<32>()?))
}

/// Uniform over 000000–999999: draws past the last whole million are redrawn.
fn six_digit_code() -> anyhow::Result<String> {
    const LIMIT: u32 = u32::MAX - u32::MAX % 1_000_000;
    loop {
        let value = u32::from_le_bytes(random_bytes::<4>()?);
        if value < LIMIT {
            return Ok(format!("{:06}", value % 1_000_000));
        }
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len() && left.iter().zip(right).fold(0u8, |difference, (a, b)| difference | (a ^ b)) == 0
}

fn normalized_email(text: &str) -> Option<String> {
    let email = text.trim().to_lowercase();
    (email.len() <= 254 && is_email(&email)).then_some(email)
}

/// The claims of a JWT, without checking its signature.
fn jwt_claims(token: &str) -> anyhow::Result<Value> {
    let payload = token.split('.').nth(1).context("malformed token")?;
    Ok(serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload.trim_end_matches('='))?)?)
}

/// Google's identity token arrives straight from Google's token endpoint
/// over TLS, so its claims are checked without verifying the signature, as
/// Google's OpenID Connect guide allows.
fn google_identity_from_token(token: &str, client: &OAuthClient, nonce: &str) -> anyhow::Result<Identity> {
    let claims = jwt_claims(token)?;
    let claim = |key: &str| claims.get(key).and_then(Value::as_str);
    anyhow::ensure!(
        matches!(claim("iss"), Some("accounts.google.com" | "https://accounts.google.com")),
        "Google identity token has another issuer"
    );
    anyhow::ensure!(claim("aud") == Some(client.id.as_str()), "Google identity token has another audience");
    anyhow::ensure!(claim("nonce") == Some(nonce), "Google identity token has another nonce");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    anyhow::ensure!(
        claims.get("exp").and_then(Value::as_u64).is_some_and(|exp| exp > now),
        "Google identity token expired"
    );
    let subject = claim("sub").filter(|sub| !sub.is_empty()).context("Google identity token has no subject")?;
    let email = claim("email").map(str::to_lowercase).filter(|email| is_email(email));
    let email_verified = email.is_some() && claims.get("email_verified").and_then(Value::as_bool) == Some(true);
    Ok(Identity { provider: "google", subject: subject.to_string(), email, email_verified })
}

/// The primary verified email, or another verified one.
fn github_verified_email(emails: &Value) -> Option<String> {
    let verified: Vec<&Value> = emails
        .as_array()?
        .iter()
        .filter(|entry| entry.get("verified").and_then(Value::as_bool) == Some(true))
        .collect();
    verified
        .iter()
        .find(|entry| entry.get("primary").and_then(Value::as_bool) == Some(true))
        .or_else(|| verified.first())
        .and_then(|entry| entry.get("email").and_then(Value::as_str))
        .map(str::to_lowercase)
        .filter(|email| is_email(email))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_challenges_follow_rfc_7636() {
        // RFC 7636 appendix B.
        assert_eq!(
            code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert!(is_code_challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
        assert!(!is_code_challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-c="));
        assert!(!is_code_challenge("short"));
    }

    #[test]
    fn codes_and_tokens_have_their_shapes() {
        for _ in 0..100 {
            let code = six_digit_code().unwrap();
            assert_eq!(code.len(), 6);
            assert!(code.bytes().all(|byte| byte.is_ascii_digit()));
        }
        let token = random_token().unwrap();
        assert_eq!(token.len(), 43);
        assert_ne!(token, random_token().unwrap());
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"abcd"));
    }

    #[test]
    fn emails_are_trimmed_lowercased_and_checked() {
        assert_eq!(normalized_email("  Lev@Example.TEST "), Some("lev@example.test".to_string()));
        assert_eq!(normalized_email("not an email"), None);
    }

    fn google_token(claims: Value) -> String {
        format!("e30.{}.signature", URL_SAFE_NO_PAD.encode(claims.to_string()))
    }

    #[test]
    fn google_tokens_need_googles_issuer_our_audience_our_nonce_and_time_left() {
        let client = OAuthClient { id: "client".to_string(), secret: "secret".to_string() };
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let claims = json!({"iss": "https://accounts.google.com", "aud": "client", "nonce": "n", "exp": now + 60,
            "sub": "123", "email": "Lev@Example.test", "email_verified": true});
        let identity = google_identity_from_token(&google_token(claims.clone()), &client, "n").unwrap();
        assert_eq!(
            identity,
            Identity {
                provider: "google",
                subject: "123".to_string(),
                email: Some("lev@example.test".to_string()),
                email_verified: true,
            }
        );
        for (key, value) in [
            ("iss", json!("https://evil.test")),
            ("aud", json!("other")),
            ("nonce", json!("x")),
            ("exp", json!(now - 1)),
        ] {
            let mut changed = claims.clone();
            changed[key] = value;
            assert!(google_identity_from_token(&google_token(changed), &client, "n").is_err(), "{key}");
        }
        let mut unverified = claims;
        unverified["email_verified"] = json!(false);
        assert!(!google_identity_from_token(&google_token(unverified), &client, "n").unwrap().email_verified);
    }

    #[test]
    fn github_prefers_the_primary_verified_email() {
        let emails = json!([
            {"email": "old@example.test", "primary": false, "verified": true},
            {"email": "Main@Example.test", "primary": true, "verified": true},
        ]);
        assert_eq!(github_verified_email(&emails), Some("main@example.test".to_string()));
        let unverified_primary = json!([
            {"email": "main@example.test", "primary": true, "verified": false},
            {"email": "other@example.test", "primary": false, "verified": true},
        ]);
        assert_eq!(github_verified_email(&unverified_primary), Some("other@example.test".to_string()));
        assert_eq!(
            github_verified_email(&json!([{"email": "x@example.test", "primary": true, "verified": false}])),
            None
        );
    }

    #[test]
    fn the_app_callback_carries_one_escaped_value() {
        assert_eq!(app_callback("code", "a b&c"), "openarc-auth://callback?code=a+b%26c");
        assert_eq!(app_callback("error", "expired"), "openarc-auth://callback?error=expired");
    }
}
