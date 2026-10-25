//! HTTP behavior that needs no database: routes, validation before auth,
//! request bodies, OpenAPI, releases and Apple identity verification.

use crate::app::{AppState, router};
use crate::auth::AuthService;
use crate::config::Config;
use crate::sync::SyncService;
use crate::updates::UpdatesService;
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use axum::routing::get;
use flate2::Compression;
use flate2::write::GzEncoder;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Write;
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;
use tower::ServiceExt;

const DEVICE: &str = "00000000-0000-4000-8000-000000000001";
const MUTATION: &str = "00000000-0000-4000-8000-000000000002";

fn config(extra: &[(&str, &str)]) -> Config {
    let mut environment = HashMap::from([
        // Never connected: these tests stop before storage.
        ("DATABASE_URL".to_string(), "postgres://test:test@127.0.0.1:1/openarc_test".to_string()),
        ("APPLE_CLIENT_ID".to_string(), "com.openarc.tests".to_string()),
        ("JWT_SECRET".to_string(), "test-secret-with-at-least-thirty-two-bytes".to_string()),
        ("JWT_ISSUER".to_string(), "openarc-sync-test".to_string()),
        ("JWT_AUDIENCE".to_string(), "openarc-test-clients".to_string()),
        ("OPENARC_PUBLIC_BASE_URL".to_string(), "https://updates.openarc.test".to_string()),
        ("GITHUB_RELEASE_REPOSITORY".to_string(), "openarc/app".to_string()),
    ]);
    for (key, value) in extra {
        environment.insert((*key).to_string(), (*value).to_string());
    }
    Config::parse(&environment).unwrap()
}

fn app_with_github(github_api: &str) -> Router {
    app_with(github_api, &[])
}

fn app_with(github_api: &str, extra: &[(&str, &str)]) -> Router {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = Arc::new(config(extra));
    let http = reqwest::Client::new();
    let auth = AuthService::new(&config, http.clone());
    let pool = crate::db::pool(&config.database_url).unwrap();
    router(AppState {
        sync: Arc::new(SyncService::new(pool, auth.clone())),
        updates: UpdatesService::new(config.clone(), http, github_api),
        auth,
        config,
    })
}

fn app() -> Router {
    app_with_github("http://127.0.0.1:1")
}

async fn send(app: Router, request: Request<Body>) -> (StatusCode, axum::http::HeaderMap, String) {
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, headers, String::from_utf8_lossy(&body).to_string())
}

fn post(path: &str, body: Vec<u8>, gzip: bool, authorization: Option<&str>) -> Request<Body> {
    let mut builder = Request::post(path).header("content-type", "application/json");
    if let Some(authorization) = authorization {
        builder = builder.header("authorization", authorization);
    }
    let body = if gzip {
        builder = builder.header("content-encoding", "gzip");
        let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
        encoder.write_all(&body).unwrap();
        encoder.finish().unwrap()
    } else {
        body
    };
    builder.body(Body::from(body)).unwrap()
}

fn json_bytes(value: &Value) -> Vec<u8> {
    serde_json::to_vec(value).unwrap()
}

#[tokio::test]
async fn reports_health() {
    let (status, headers, body) = send(app(), Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-type"], "application/json; charset=utf-8");
    assert_eq!(body, r#"{"ok":true}"#);
    // Express also matched a trailing slash.
    let (status, _, _) = send(app(), Request::get("/health/").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn serves_openapi_yaml_json_and_docs() {
    let (status, headers, body) = send(app(), Request::get("/openapi.json").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers["content-type"].to_str().unwrap().contains("application/json"));
    let document: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(document["info"]["title"], "OpenArc Sync API");
    assert!(document["paths"]["/health"].is_object());
    assert_eq!(document["paths"]["/v1/sync/push"]["post"]["security"], json!([{"bearerAuth": []}]));

    let (status, headers, body) = send(app(), Request::get("/openapi.yaml").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers["content-type"].to_str().unwrap().contains("application/yaml"));
    assert!(body.contains("openapi: 3.0.3") && body.contains("/v1/sync/push:"));

    let (status, headers, body) = send(app(), Request::get("/docs").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers["content-type"].to_str().unwrap().contains("text/html"));
    assert!(body.contains("/openapi.json"));
}

#[tokio::test]
async fn unknown_routes_and_methods_answer_like_express() {
    let (status, _, body) = send(app(), Request::get("/v1/sync/push").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(
        serde_json::from_str::<Value>(&body).unwrap(),
        json!({"message": "Cannot GET /v1/sync/push", "error": "Not Found", "statusCode": 404})
    );
}

#[tokio::test]
async fn requires_auth_before_sync_push_reaches_storage() {
    let request = post("/v1/sync/push", json_bytes(&json!({"deviceID": DEVICE, "changes": []})), false, None);
    let (status, _, body) = send(app(), request).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body, r#"{"error":"unauthorized"}"#);
}

#[tokio::test]
async fn validates_sync_pull_request_bodies_before_auth() {
    let body = json_bytes(&json!({"deviceID": "not-a-uuid", "cursor": -1, "limit": 1001}));
    let (status, _, body) = send(app(), post("/v1/sync/pull", body, false, Some("Bearer invalid-token"))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let message = serde_json::from_str::<Value>(&body).unwrap()["message"].as_str().unwrap().to_string();
    assert!(message.contains("deviceID") || message.contains("cursor") || message.contains("limit"), "{message}");
}

#[tokio::test]
async fn non_json_and_malformed_bodies_are_rejected() {
    let request = Request::post("/v1/sync/pull").header("content-type", "text/plain").body(Body::from("{}")).unwrap();
    assert_eq!(send(app(), request).await.0, StatusCode::BAD_REQUEST);
    let (status, _, body) = send(app(), post("/v1/sync/pull", b"{\"deviceID\":".to_vec(), false, None)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["statusCode"], 400);
    let request = Request::post("/v1/sync/pull")
        .header("content-type", "application/json")
        .header("content-encoding", "zstd")
        .body(Body::from("{}"))
        .unwrap();
    assert_eq!(send(app(), request).await.0, StatusCode::UNSUPPORTED_MEDIA_TYPE);
}

#[tokio::test]
async fn decompresses_gzipped_json_request_bodies_before_auth_handling() {
    let body = json_bytes(&json!({"deviceID": DEVICE, "changes": []}));
    let (status, _, body) = send(app(), post("/v1/sync/push", body, true, None)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body, r#"{"error":"unauthorized"}"#);
}

#[tokio::test]
async fn parses_a_declared_1000_operation_batch_beyond_100_kib_before_auth() {
    let operations: Vec<Value> = (0..1000)
        .map(|index| {
            json!({"kind": "patch", "entityType": "tab", "entityID": format!("tab-{index}"),
                "fields": {"userTitleOverride": "large legitimate batch ".repeat(10)}})
        })
        .collect();
    let body = json_bytes(
        &json!({"protocolVersion": 3, "mutationID": MUTATION, "deviceID": DEVICE, "operations": operations}),
    );
    assert!(body.len() > 100 * 1024);
    for gzip in [false, true] {
        let (status, _, response) = send(app(), post("/v1/sync/push", body.clone(), gzip, None)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{response}");
    }
}

#[tokio::test]
async fn bounds_inflated_json_at_8_mib_for_plain_and_gzip_requests() {
    let body = json_bytes(&json!({"protocolVersion": 3, "mutationID": MUTATION, "deviceID": DEVICE,
        "operations": [{"kind": "patch", "entityType": "tab", "entityID": "tab",
            "fields": {"userTitleOverride": "x".repeat(9 * 1024 * 1024)}}]}));
    for gzip in [false, true] {
        let (status, _, response) = send(app(), post("/v1/sync/push", body.clone(), gzip, None)).await;
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "{response}");
    }
}

#[tokio::test]
async fn compresses_large_json_responses_only_when_asked() {
    let request = Request::get("/openapi.json").header("accept-encoding", "gzip").body(Body::empty()).unwrap();
    let (status, headers, _) = send(app(), request).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers["content-encoding"], "gzip");
    let (_, headers, _) =
        send(app(), Request::get("/health").header("accept-encoding", "gzip").body(Body::empty()).unwrap()).await;
    assert!(headers.get("content-encoding").is_none(), "small bodies stay uncompressed");
}

/// A local GitHub that records every request.
async fn fake_github() -> (String, Arc<Mutex<Vec<(String, String)>>>) {
    let calls: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let recorded = calls.clone();
    let download_url = format!("{base}/download/12345");
    let app = Router::new().fallback(get(move |request: Request<Body>| {
        let recorded = recorded.clone();
        let download_url = download_url.clone();
        async move {
            let accept =
                request.headers().get("accept").and_then(|value| value.to_str().ok()).unwrap_or_default().to_string();
            recorded.lock().unwrap().push((request.uri().path().to_string(), accept));
            if request.uri().path() == "/repos/openarc/app/releases/assets/12345" {
                axum::Json(json!({"id": 12345, "name": "OpenArc-1.0.0.dmg", "url": download_url,
                    "content_type": "application/x-apple-diskimage", "size": 42}))
                .into_response()
            } else {
                StatusCode::IM_A_TEAPOT.into_response()
            }
        }
    }));
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, calls)
}

use axum::response::IntoResponse;

#[tokio::test]
async fn rejects_mismatched_release_asset_filenames_before_fetching_the_asset_body() {
    let (github, calls) = fake_github().await;
    let request = Request::get("/v1/releases/assets/12345/Misleading.dmg").body(Body::empty()).unwrap();
    let (status, _, _) = send(app_with_github(&github), request).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let calls = calls.lock().unwrap().clone();
    assert!(calls.iter().any(|(path, _)| path == "/repos/openarc/app/releases/assets/12345"));
    assert!(!calls.iter().any(|(path, _)| path == "/download/12345"));
    assert!(!calls.iter().any(|(_, accept)| accept == "application/octet-stream"));
    let (status, _, _) =
        send(app_with_github(&github), Request::get("/v1/releases/assets/12x/a.dmg").body(Body::empty()).unwrap())
            .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn release_channels_and_limits_are_validated() {
    let (github, _) = fake_github().await;
    for path in
        ["/v1/releases?channel=nightly", "/v1/releases?limit=0", "/v1/releases?limit=101", "/appcast.xml?channel=x"]
    {
        let (status, _, body) = send(app_with_github(&github), Request::get(path).body(Body::empty()).unwrap()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{path}: {body}");
    }
}

#[tokio::test]
async fn routes_ignore_case_and_404s_name_the_original_url() {
    for path in ["/HEALTH", "/Health/", "/health"] {
        assert_eq!(send(app(), Request::get(path).body(Body::empty()).unwrap()).await.0, StatusCode::OK, "{path}");
    }
    let (status, _, body) = send(app(), Request::get("/nope/?x=1").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["message"], "Cannot GET /nope/?x=1");
}

#[tokio::test]
async fn responses_carry_weak_etags_and_fresh_requests_get_304() {
    let (status, headers, _) = send(app(), Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    let tag = headers["etag"].to_str().unwrap().to_string();
    // Express (computed with Node): W/"<length in hex>-<27 characters of base64 SHA-1>".
    assert_eq!(tag, "W/\"b-Ai2R8hgEarLmHKwesT1qcY913ys\"");
    let request = Request::get("/health").header("if-none-match", tag.clone()).body(Body::empty()).unwrap();
    let (status, headers, body) = send(app(), request).await;
    assert_eq!(status, StatusCode::NOT_MODIFIED);
    assert!(body.is_empty() && headers.get("content-type").is_none());
    let request = Request::get("/health")
        .header("if-none-match", tag)
        .header("cache-control", "no-cache")
        .body(Body::empty())
        .unwrap();
    assert_eq!(send(app(), request).await.0, StatusCode::OK);
}

#[tokio::test]
async fn bodies_follow_expresss_parsers() {
    let with = |content_type: &str, encoding: Option<&str>, body: &[u8]| {
        let mut builder = Request::post("/v1/devices").header("content-type", content_type);
        if let Some(encoding) = encoding {
            builder = builder.header("content-encoding", encoding);
        }
        builder.body(Body::from(body.to_vec())).unwrap()
    };
    // A valid form passes validation and stops at authentication.
    let (status, _, _) = send(app(), with("application/x-www-form-urlencoded", None, b"name=Mac&platform=macOS")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, _) = send(app(), with("application/x-www-form-urlencoded", None, b"name=Mac")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    // A byte order mark is skipped.
    let (status, _, _) =
        send(app(), with("application/json", None, b"\xEF\xBB\xBF{\"name\":\"Mac\",\"platform\":\"macOS\"}")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    // Syntax errors, including a body of spaces, are Bad Requests.
    for body in [&b"  "[..], b"{\"name\":", b"\"text\""] {
        let (status, _, response) = send(app(), with("application/json", None, body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["error"], "Bad Request");
    }
    for (content_type, encoding) in [("application/json", Some("x-gzip")), ("application/json; charset=latin1", None)] {
        let (status, _, _) = send(app(), with(content_type, encoding, b"{}")).await;
        assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE, "{content_type} {encoding:?}");
    }
}

#[tokio::test]
async fn cors_answers_every_options_request_for_the_configured_origin() {
    let cors = || app_with("http://127.0.0.1:1", &[("CORS_ORIGIN", "https://app.openarc.test")]);
    let request = Request::options("/v1/sync/pull").body(Body::empty()).unwrap();
    let (status, headers, _) = send(cors(), request).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(headers["access-control-allow-origin"], "https://app.openarc.test");
    assert_eq!(headers["access-control-allow-methods"], "GET,HEAD,PUT,PATCH,POST,DELETE");
    let (_, headers, _) = send(cors(), Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(headers["access-control-allow-origin"], "https://app.openarc.test");
    let (status, headers, _) = send(app(), Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers.get("access-control-allow-origin").is_none());
}

#[tokio::test]
async fn repeated_query_parameters_are_rejected_with_json() {
    let (github, _) = fake_github().await;
    for path in ["/appcast.xml?channel=stable&channel=beta", "/v1/releases?limit=5&limit=6"] {
        let (status, headers, body) =
            send(app_with_github(&github), Request::get(path).body(Body::empty()).unwrap()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{path}");
        assert!(headers["content-type"].to_str().unwrap().contains("application/json"));
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["statusCode"], 400);
    }
}

// MARK: Apple identity tokens

mod apple {
    use super::*;
    use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
    use rsa::pkcs1::EncodeRsaPrivateKey;
    use rsa::traits::PublicKeyParts;

    const DESKTOP: &str = "com.openarc.auth-test-desktop";
    const MOBILE: &str = "com.openarc.auth-test-mobile";

    struct Fixture {
        auth: AuthService,
        key: EncodingKey,
        requests: Arc<Mutex<usize>>,
    }

    async fn fixture() -> Fixture {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let private = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let public = private.to_public_key();
        let encode64 = |bytes: Vec<u8>| base64_url_encode(&bytes);
        let jwk = json!({"kty": "RSA", "kid": "local-apple-test-key", "alg": "RS256", "use": "sig",
            "n": encode64(public.n().to_bytes_be()), "e": encode64(public.e().to_bytes_be())});
        let requests: Arc<Mutex<usize>> = Arc::default();
        let counter = requests.clone();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/keys", listener.local_addr().unwrap());
        let app = Router::new().route(
            "/keys",
            get(move || {
                let counter = counter.clone();
                let jwk = jwk.clone();
                async move {
                    *counter.lock().unwrap() += 1;
                    axum::Json(json!({"keys": [jwk]}))
                }
            }),
        );
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let ids = format!(" {DESKTOP}, {MOBILE} ");
        let config = super::config(&[("APPLE_CLIENT_ID", DESKTOP), ("APPLE_CLIENT_IDS", &ids)]);
        assert_eq!(config.apple_client_ids, vec![DESKTOP, MOBILE]);
        let pem = private.to_pkcs1_pem(rsa::pkcs1::LineEnding::LF).unwrap();
        Fixture {
            // Only key transport is local; signatures, expiry, issuer and
            // audience are verified as in production.
            auth: AuthService::with_apple_keys_url(&config, reqwest::Client::new(), &url),
            key: EncodingKey::from_rsa_pem(pem.as_bytes()).unwrap(),
            requests,
        }
    }

    fn token(fixture: &Fixture, audience: &str, issuer: &str, expired: bool) -> String {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        let mut header = Header::new(Algorithm::RS256);
        header.kid = Some("local-apple-test-key".to_string());
        let claims = json!({"email": "local@example.test", "sub": "local-apple-subject", "iss": issuer, "aud": audience,
            "iat": now, "exp": if expired { now - 1 } else { now + 300 }});
        encode(&header, &claims, &fixture.key).unwrap()
    }

    #[tokio::test]
    async fn accepts_exactly_the_configured_desktop_and_mobile_clients() {
        let fixture = fixture().await;
        for audience in [DESKTOP, MOBILE] {
            let identity = fixture
                .auth
                .verify_apple_identity_token(&token(&fixture, audience, "https://appleid.apple.com", false))
                .await
                .unwrap();
            assert_eq!(identity.apple_subject, "local-apple-subject");
            assert_eq!(identity.email.as_deref(), Some("local@example.test"));
        }
        assert!(*fixture.requests.lock().unwrap() > 0, "the fixture must fetch its local key set");
    }

    #[tokio::test]
    async fn rejects_unlisted_and_lookalike_audiences_wrong_issuers_and_expired_tokens() {
        let fixture = fixture().await;
        let mobile_upper = MOBILE.to_uppercase();
        let lookalike = format!("{MOBILE}.other");
        for audience in ["com.openarc.unlisted", lookalike.as_str(), mobile_upper.as_str()] {
            let token = token(&fixture, audience, "https://appleid.apple.com", false);
            assert!(fixture.auth.verify_apple_identity_token(&token).await.is_err(), "{audience}");
        }
        let wrong_issuer = token(&fixture, MOBILE, "https://not-apple.example.test", false);
        assert!(fixture.auth.verify_apple_identity_token(&wrong_issuer).await.is_err());
        let expired = token(&fixture, MOBILE, "https://appleid.apple.com", true);
        assert!(fixture.auth.verify_apple_identity_token(&expired).await.is_err());
    }

    fn base64_url_encode(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut output = String::new();
        for chunk in bytes.chunks(3) {
            let value = chunk
                .iter()
                .enumerate()
                .fold(0u32, |value, (index, byte)| value | (u32::from(*byte) << (16 - 8 * index)));
            for index in 0..=chunk.len() {
                output.push(ALPHABET[((value >> (18 - 6 * index)) & 63) as usize] as char);
            }
        }
        output
    }
}
