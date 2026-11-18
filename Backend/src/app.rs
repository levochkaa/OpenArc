//! Routes, request validation order (body first, then the bearer token) and
//! response conventions: JSON as JavaScript wrote it, 201 for POST.

use crate::auth::AuthService;
use crate::body::JsonBody;
use crate::config::Config;
use crate::error::{ApiError, ApiResult, json_response};
use crate::requests::{
    AUTH_APPLE_REQUEST, AUTH_EMAIL_START_REQUEST, AUTH_EMAIL_VERIFY_REQUEST, AUTH_WEB_EXCHANGE_REQUEST,
    REGISTER_DEVICE_REQUEST, SHARE_PUBLISH_REQUEST, SYNC_PULL_REQUEST, SYNC_PUSH_REQUEST,
};
use crate::schema::{Schema, format_issues};
use crate::shares::{Kind, ShareService, page};
use crate::signin::{SignInService, WebProvider};
use crate::sync::{SyncService, parse_uuid};
use crate::updates::{Channel, Download, UpdatesService, content_disposition, parse_channel};
use axum::Router;
use axum::body::Body;
use axum::extract::rejection::PathRejection;
use axum::extract::{Path, Request, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use std::collections::HashMap;
use std::sync::Arc;
use tower_http::compression::CompressionLayer;
use tower_http::compression::predicate::{Predicate, SizeAbove};

pub const OPENAPI_YAML: &str = include_str!("../openapi.yaml");

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub auth: AuthService,
    pub sync: Arc<SyncService>,
    pub sign_in: SignInService,
    pub updates: UpdatesService,
    pub shares: Arc<ShareService>,
}

pub fn router(state: AppState) -> Router {
    let cors_origin = state.config.cors_origin.clone();
    let routes = Router::new()
        .route("/health", get(|| async { json_response(StatusCode::OK, &json!({"ok": true})) }))
        .route("/openapi.yaml", get(openapi_yaml))
        .route("/openapi.json", get(openapi_json))
        .route("/docs", get(docs))
        .route("/docs-yaml", get(openapi_yaml))
        .route("/v1/auth/apple", post(authenticate_with_apple))
        .route("/v1/auth/providers", get(auth_providers))
        .route("/v1/auth/web/{provider}/start", get(start_web_sign_in))
        .route("/v1/auth/apple/callback", post(apple_callback))
        .route("/v1/auth/google/callback", get(google_callback))
        .route("/v1/auth/github/callback", get(github_callback))
        .route("/v1/auth/web/exchange", post(exchange_web_sign_in))
        .route("/v1/auth/email/start", post(start_email_sign_in))
        .route("/v1/auth/email/verify", post(verify_email_sign_in))
        .route("/v1/devices", post(register_device))
        .route("/v1/sync/push", post(push))
        .route("/v1/sync/pull", post(pull))
        .route("/v1/shares", post(publish_share).get(list_shares))
        .route("/v1/shares/{id}", get(read_share).delete(delete_share))
        .route("/s/{id}", get(share_page))
        .route("/q/{id}", get(quote_page))
        .route("/appcast.xml", get(appcast))
        .route("/updates/appcast.xml", get(appcast))
        .route("/appcast-beta.xml", get(beta_appcast))
        .route("/updates/appcast-beta.xml", get(beta_appcast))
        .route("/downloads/{asset_name}", get(sparkle_download))
        .route("/updates/downloads/{asset_name}", get(sparkle_download))
        .route("/v1/releases", get(releases))
        .route("/v1/releases/assets/{asset_id}/{asset_name}", get(release_asset_download))
        .fallback(not_found)
        .method_not_allowed_fallback(not_found)
        .with_state(state);
    // Path rewrites must happen before routing, so the routes sit inside a
    // router of their own.
    Router::new()
        .fallback_service(routes)
        .layer(middleware::from_fn(etag))
        .layer(CompressionLayer::new().compress_when(SizeAbove::new(1024).and(Compressible)))
        .layer(middleware::from_fn(move |request, next| cors(cors_origin.clone(), request, next)))
        .layer(middleware::from_fn(normalize_path))
}

fn parse(schema: &Schema, body: Option<Value>) -> ApiResult<Value> {
    // A request without a JSON body validates as `undefined`.
    let issues = match body {
        Some(value) => match schema.parse(&value) {
            Ok(parsed) => return Ok(parsed),
            Err(issues) => issues,
        },
        None => vec![crate::schema::Issue {
            path: Vec::new(),
            message: "Invalid input: expected object, received undefined".to_string(),
            aborts: true,
        }],
    };
    Err(ApiError::BadRequest(format_issues(&issues)))
}

fn authorized_user(state: &AppState, headers: &HeaderMap) -> ApiResult<uuid::Uuid> {
    let authorization = headers.get(header::AUTHORIZATION).and_then(|value| value.to_str().ok());
    let user_id = state.auth.user_id_from_authorization(authorization)?;
    parse_uuid(&user_id)
}

fn created(body: &Value) -> Response {
    json_response(StatusCode::CREATED, body)
}

async fn authenticate_with_apple(State(state): State<AppState>, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&AUTH_APPLE_REQUEST, body)?;
    Ok(created(&state.sync.authenticate_with_apple(&request).await?))
}

async fn auth_providers(State(state): State<AppState>) -> Response {
    no_store(json_response(StatusCode::OK, &state.sign_in.providers()))
}

async fn start_web_sign_in(
    State(state): State<AppState>,
    provider: Result<Path<String>, PathRejection>,
    request: Request,
) -> ApiResult<Response> {
    let provider = path_value(provider)?;
    let query = query_values(&request);
    let challenge = single(&query, "code_challenge", "code_challenge must appear once")?;
    Ok(see_other(&state.sign_in.start_web(&provider, challenge).await?))
}

/// Apple posts its result as a form, so its name and email can come along.
async fn apple_callback(State(state): State<AppState>, body: axum::body::Bytes) -> Response {
    let params: HashMap<String, String> = url::form_urlencoded::parse(&body).into_owned().collect();
    see_other(&state.sign_in.finish_web(WebProvider::Apple, &params).await)
}

async fn google_callback(State(state): State<AppState>, request: Request) -> Response {
    let params = first_query_values(&request);
    see_other(&state.sign_in.finish_web(WebProvider::Google, &params).await)
}

async fn github_callback(State(state): State<AppState>, request: Request) -> Response {
    let params = first_query_values(&request);
    see_other(&state.sign_in.finish_web(WebProvider::Github, &params).await)
}

async fn exchange_web_sign_in(State(state): State<AppState>, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&AUTH_WEB_EXCHANGE_REQUEST, body)?;
    Ok(no_store(created(&state.sign_in.exchange_web(&request).await?)))
}

async fn start_email_sign_in(State(state): State<AppState>, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&AUTH_EMAIL_START_REQUEST, body)?;
    Ok(json_response(StatusCode::ACCEPTED, &state.sign_in.start_email(&request).await?))
}

async fn verify_email_sign_in(State(state): State<AppState>, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&AUTH_EMAIL_VERIFY_REQUEST, body)?;
    Ok(no_store(created(&state.sign_in.verify_email(&request).await?)))
}

/// The first value of each query parameter; providers send each once.
fn first_query_values(request: &Request) -> HashMap<String, String> {
    query_values(request)
        .into_iter()
        .filter_map(|(key, values)| values.into_iter().next().map(|value| (key, value)))
        .collect()
}

fn see_other(location: &str) -> Response {
    let mut response = StatusCode::SEE_OTHER.into_response();
    if let Ok(value) = HeaderValue::from_str(location) {
        response.headers_mut().insert(header::LOCATION, value);
    }
    no_store(response)
}

fn no_store(mut response: Response) -> Response {
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    JsonBody(body): JsonBody,
) -> ApiResult<Response> {
    let request = parse(&REGISTER_DEVICE_REQUEST, body)?;
    let user_id = authorized_user(&state, &headers)?;
    Ok(created(&state.sync.register_device(user_id, &request).await?))
}

async fn push(State(state): State<AppState>, headers: HeaderMap, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&SYNC_PUSH_REQUEST, body)?;
    let user_id = authorized_user(&state, &headers)?;
    Ok(created(&state.sync.push(user_id, &request).await?))
}

async fn pull(State(state): State<AppState>, headers: HeaderMap, JsonBody(body): JsonBody) -> ApiResult<Response> {
    let request = parse(&SYNC_PULL_REQUEST, body)?;
    let user_id = authorized_user(&state, &headers)?;
    Ok(created(&state.sync.pull(user_id, &request).await?))
}

// MARK: Shares

async fn publish_share(
    State(state): State<AppState>,
    headers: HeaderMap,
    JsonBody(body): JsonBody,
) -> ApiResult<Response> {
    let request = parse(&SHARE_PUBLISH_REQUEST, body)?;
    let user_id = authorized_user(&state, &headers)?;
    Ok(no_store(created(&state.shares.publish(user_id, &request).await?)))
}

async fn list_shares(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let user_id = authorized_user(&state, &headers)?;
    Ok(no_store(json_response(StatusCode::OK, &state.shares.list(user_id).await?)))
}

async fn delete_share(
    State(state): State<AppState>,
    headers: HeaderMap,
    id: Result<Path<String>, PathRejection>,
) -> ApiResult<Response> {
    let id = path_value(id)?;
    let user_id = authorized_user(&state, &headers)?;
    state.shares.delete(user_id, &id).await?;
    Ok(no_store(StatusCode::NO_CONTENT.into_response()))
}

/// The content of a link, which the app reads to add it.
async fn read_share(State(state): State<AppState>, id: Result<Path<String>, PathRejection>) -> ApiResult<Response> {
    let id = path_value(id)?;
    let share = state.shares.find(&id).await?.ok_or_else(|| ApiError::status(404, "Share not found"))?;
    let mut response = json_response(StatusCode::OK, &state.shares.public_json(&share));
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=60"));
    Ok(response)
}

async fn share_page(State(state): State<AppState>, id: Result<Path<String>, PathRejection>) -> ApiResult<Response> {
    public_page(&state, Kind::Space, id).await
}

async fn quote_page(State(state): State<AppState>, id: Result<Path<String>, PathRejection>) -> ApiResult<Response> {
    public_page(&state, Kind::Quote, id).await
}

/// `/s/` shows Spaces and folders, `/q/` quotes; the other path redirects.
async fn public_page(
    state: &AppState,
    path_kind: Kind,
    id: Result<Path<String>, PathRejection>,
) -> ApiResult<Response> {
    let id = path_value(id).unwrap_or_default();
    let Some(share) = state.shares.find(&id).await? else {
        return Ok(html_response(StatusCode::NOT_FOUND, page::missing()));
    };
    let url = state.shares.page_url(share.kind, &share.id);
    if share.kind.path() != path_kind.path() {
        let mut response = StatusCode::MOVED_PERMANENTLY.into_response();
        if let Ok(value) = HeaderValue::from_str(&url) {
            response.headers_mut().insert(header::LOCATION, value);
        }
        return Ok(response);
    }
    let html = match share.kind {
        Kind::Quote => page::quote(&share, &url),
        Kind::Space | Kind::Folder => page::collection(&share, &url),
    };
    Ok(html_response(StatusCode::OK, html))
}

fn html_response(status: StatusCode, html: String) -> Response {
    let mut response = (status, html).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/html; charset=utf-8"));
    headers.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static(page::CONTENT_SECURITY_POLICY));
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(header::REFERRER_POLICY, HeaderValue::from_static("strict-origin-when-cross-origin"));
    headers.insert("x-robots-tag", HeaderValue::from_static("noindex"));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=60"));
    response
}

// MARK: OpenAPI

async fn openapi_yaml() -> Response {
    with_content_type(OPENAPI_YAML.into_response(), "application/yaml; charset=utf-8")
}

async fn openapi_json() -> ApiResult<Response> {
    let document: Value = serde_yaml::from_str(OPENAPI_YAML)?;
    Ok(json_response(StatusCode::OK, &document))
}

async fn docs() -> Response {
    const PAGE: &str = r##"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OpenArc Sync API</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({ url: "/openapi.json", dom_id: "#swagger-ui", deepLinking: true, docExpansion: "list" });
  </script>
</body>
</html>
"##;
    with_content_type(PAGE.into_response(), "text/html; charset=utf-8")
}

// MARK: Updates

/// Query values by name, every occurrence kept.
fn query_values(request: &Request) -> HashMap<String, Vec<String>> {
    let mut values: HashMap<String, Vec<String>> = HashMap::new();
    for (key, value) in url::form_urlencoded::parse(request.uri().query().unwrap_or_default().as_bytes()) {
        values.entry(key.into_owned()).or_default().push(value.into_owned());
    }
    values
}

/// The one value of a query parameter. Express parsed a repeated parameter
/// into an array, which no parameter here accepts.
fn single<'q>(values: &'q HashMap<String, Vec<String>>, name: &str, error: &str) -> ApiResult<Option<&'q str>> {
    match values.get(name).map(Vec::as_slice) {
        None => Ok(None),
        Some([value]) => Ok(Some(value.as_str())),
        Some(_) => Err(ApiError::status(400, error)),
    }
}

const CHANNEL_ERROR: &str = "Release channel must be stable or beta";
const LIMIT_ERROR: &str = "Release limit must be an integer from 1 to 100";

async fn appcast(State(state): State<AppState>, request: Request) -> ApiResult<Response> {
    let query = query_values(&request);
    let channel = parse_channel(single(&query, "channel", CHANNEL_ERROR)?.unwrap_or("stable"))?;
    appcast_response(&state, channel).await
}

async fn beta_appcast(State(state): State<AppState>) -> ApiResult<Response> {
    appcast_response(&state, Channel::Beta).await
}

async fn appcast_response(state: &AppState, channel: Channel) -> ApiResult<Response> {
    let mut response = state.updates.sparkle_appcast(channel).await?.into_response();
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=60"));
    headers.insert(header::VARY, HeaderValue::from_static("Accept"));
    Ok(with_content_type(response, "application/xml; charset=utf-8"))
}

/// An undecodable path parameter is a Bad Request, as in Nest.
fn path_value<T>(path: Result<Path<T>, PathRejection>) -> ApiResult<T> {
    path.map(|Path(value)| value).map_err(|rejection| ApiError::BadRequest(rejection.body_text()))
}

async fn sparkle_download(
    State(state): State<AppState>,
    asset_name: Result<Path<String>, PathRejection>,
) -> ApiResult<Response> {
    let asset_name = path_value(asset_name)?;
    Ok(download_response(state.updates.sparkle_download(&asset_name).await?))
}

async fn release_asset_download(
    State(state): State<AppState>,
    path: Result<Path<(String, String)>, PathRejection>,
) -> ApiResult<Response> {
    let (asset_id, asset_name) = path_value(path)?;
    Ok(download_response(state.updates.release_asset_download(&asset_id, &asset_name).await?))
}

fn download_response(download: Download) -> Response {
    let Download { asset, response: upstream } = download;
    let mut response = Response::new(Body::from_stream(upstream.bytes_stream()));
    let headers = response.headers_mut();
    if let Some(size) = asset.size.filter(|size| *size > 0) {
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from(size));
    }
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=31536000, immutable"));
    if let Ok(value) = HeaderValue::from_str(&content_disposition(&asset.name)) {
        headers.insert(header::CONTENT_DISPOSITION, value);
    }
    let content_type = asset.content_type.as_deref().unwrap_or("application/octet-stream");
    with_content_type(response, content_type)
}

async fn releases(State(state): State<AppState>, request: Request) -> ApiResult<Response> {
    let query = query_values(&request);
    let channel = single(&query, "channel", CHANNEL_ERROR)?;
    let limit = single(&query, "limit", LIMIT_ERROR)?;
    let index = state.updates.release_index(channel, limit, request.headers()).await?;
    let mut response = json_response(StatusCode::OK, &index);
    response.headers_mut().insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, HeaderValue::from_static("*"));
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=60"));
    Ok(response)
}

// MARK: Middleware

/// The request URL before path normalization, which a 404 names.
#[derive(Clone)]
struct OriginalUrl(String);

async fn not_found(method: Method, request: Request) -> ApiError {
    let path = match request.extensions().get::<OriginalUrl>() {
        Some(OriginalUrl(url)) => url.clone(),
        None => request.uri().to_string(),
    };
    ApiError::RouteNotFound { method: method.to_string(), path }
}

fn with_content_type(mut response: Response, content_type: &str) -> Response {
    if let Ok(value) = HeaderValue::from_str(content_type) {
        response.headers_mut().insert(header::CONTENT_TYPE, value);
    }
    response
}

const STATIC_ROUTES: &[&str] = &[
    "/health",
    "/openapi.yaml",
    "/openapi.json",
    "/docs",
    "/docs-yaml",
    "/v1/auth/apple",
    "/v1/auth/providers",
    "/v1/auth/apple/callback",
    "/v1/auth/google/callback",
    "/v1/auth/github/callback",
    "/v1/auth/web/exchange",
    "/v1/auth/email/start",
    "/v1/auth/email/verify",
    "/v1/devices",
    "/v1/sync/push",
    "/v1/sync/pull",
    "/appcast.xml",
    "/updates/appcast.xml",
    "/appcast-beta.xml",
    "/updates/appcast-beta.xml",
    "/v1/releases",
    "/v1/shares",
];
const PARAMETER_ROUTE_PREFIXES: &[&str] =
    &["/downloads/", "/updates/downloads/", "/v1/releases/assets/", "/v1/auth/web/", "/v1/shares/", "/s/", "/q/"];

/// Express routes match without regard to case and with one optional
/// trailing slash; parameters keep their case.
fn normalized_path(path: &str) -> String {
    let path = if path.len() > 1 { path.strip_suffix('/').unwrap_or(path) } else { path };
    if let Some(route) = STATIC_ROUTES.iter().find(|route| route.eq_ignore_ascii_case(path)) {
        return (*route).to_string();
    }
    for prefix in PARAMETER_ROUTE_PREFIXES {
        if let Some(head) = path.get(..prefix.len())
            && head.eq_ignore_ascii_case(prefix)
            && path.len() > prefix.len()
        {
            return format!("{prefix}{}", &path[prefix.len()..]);
        }
    }
    path.to_string()
}

async fn normalize_path(mut request: Request, next: Next) -> Response {
    let original = request.uri().path_and_query().map_or_else(|| request.uri().path().to_string(), ToString::to_string);
    let path = normalized_path(request.uri().path());
    if path != request.uri().path() {
        let rebuilt = match request.uri().query() {
            Some(query) => format!("{path}?{query}"),
            None => path,
        };
        if let Ok(uri) = rebuilt.parse() {
            *request.uri_mut() = uri;
        }
    }
    request.extensions_mut().insert(OriginalUrl(original));
    next.run(request).await
}

/// Express's weak ETag of a response body, and 304 for a fresh GET or HEAD.
/// Streamed downloads have no known length and carry none.
async fn etag(request: Request, next: Next) -> Response {
    let conditional = matches!(*request.method(), Method::GET | Method::HEAD);
    let if_none_match =
        request.headers().get(header::IF_NONE_MATCH).and_then(|value| value.to_str().ok()).map(str::to_string);
    let no_cache = request
        .headers()
        .get(header::CACHE_CONTROL)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.to_ascii_lowercase().contains("no-cache"))
        // Without Last-Modified a date condition is never fresh.
        || request.headers().contains_key(header::IF_MODIFIED_SINCE);
    let response = next.run(request).await;
    if response.headers().contains_key(header::ETAG) || http_body::Body::size_hint(response.body()).exact().is_none() {
        return response;
    }
    let (mut parts, body) = response.into_parts();
    let Ok(collected) = body.collect().await else { return StatusCode::INTERNAL_SERVER_ERROR.into_response() };
    let bytes = collected.to_bytes();
    if bytes.is_empty() {
        return Response::from_parts(parts, Body::from(bytes));
    }
    let digest = base64::engine::general_purpose::STANDARD.encode(Sha1::digest(&bytes));
    let tag = format!("W/\"{:x}-{}\"", bytes.len(), &digest[..27]);
    if let Ok(value) = HeaderValue::from_str(&tag) {
        parts.headers.insert(header::ETAG, value);
    }
    let fresh = conditional
        && parts.status.is_success()
        && !no_cache
        && if_none_match.is_some_and(|header| {
            header.split(',').map(str::trim).any(|candidate| {
                candidate == "*"
                    || candidate == tag
                    || format!("W/{candidate}") == tag
                    || candidate.trim_start_matches("W/") == &tag[2..]
            })
        });
    if fresh {
        parts.status = StatusCode::NOT_MODIFIED;
        for name in [header::CONTENT_TYPE, header::CONTENT_LENGTH, header::TRANSFER_ENCODING] {
            parts.headers.remove(name);
        }
        return Response::from_parts(parts, Body::empty());
    }
    Response::from_parts(parts, Body::from(bytes))
}

/// The configured origin on every response, and preflight answers, as the
/// `cors` package does for a fixed origin. An empty origin disables CORS.
async fn cors(origin: String, request: Request, next: Next) -> Response {
    if origin.is_empty() {
        return next.run(request).await;
    }
    // The `cors` package answers every OPTIONS request as a preflight.
    let is_preflight = request.method() == Method::OPTIONS;
    let requested_headers = request.headers().get(header::ACCESS_CONTROL_REQUEST_HEADERS).cloned();
    let mut response = if is_preflight { StatusCode::NO_CONTENT.into_response() } else { next.run(request).await };
    let headers = response.headers_mut();
    if !headers.contains_key(header::ACCESS_CONTROL_ALLOW_ORIGIN)
        && let Ok(value) = HeaderValue::from_str(&origin)
    {
        headers.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
    }
    headers.append(header::VARY, HeaderValue::from_static("Origin"));
    if is_preflight {
        headers
            .insert(header::ACCESS_CONTROL_ALLOW_METHODS, HeaderValue::from_static("GET,HEAD,PUT,PATCH,POST,DELETE"));
        if let Some(requested) = requested_headers {
            headers.insert(header::ACCESS_CONTROL_ALLOW_HEADERS, requested);
            headers.append(header::VARY, HeaderValue::from_static("Access-Control-Request-Headers"));
        }
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("0"));
    }
    response
}

/// Text, JSON, XML and YAML; never release binaries.
#[derive(Clone, Copy)]
struct Compressible;

impl Predicate for Compressible {
    fn should_compress<B>(&self, response: &axum::http::Response<B>) -> bool
    where
        B: axum::body::HttpBody,
    {
        let Some(content_type) = response.headers().get(header::CONTENT_TYPE).and_then(|value| value.to_str().ok())
        else {
            return false;
        };
        let mime = content_type.split(';').next().unwrap_or_default().trim().to_ascii_lowercase();
        mime.starts_with("text/")
            || mime.ends_with("+json")
            || mime.ends_with("+xml")
            || matches!(
                mime.as_str(),
                "application/json" | "application/xml" | "application/yaml" | "application/javascript"
            )
    }
}
