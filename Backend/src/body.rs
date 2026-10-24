//! Request bodies as Express's JSON and URL-encoded parsers read them:
//! optional gzip, deflate or Brotli encoding, limits on the inflated size,
//! `undefined` for other content types and 413 past the limit.

use crate::error::ApiError;
use axum::body::Bytes;
use axum::extract::{FromRequest, Request};
use axum::http::{HeaderMap, StatusCode, header};
use http_body_util::{BodyExt, Limited};
use serde_json::{Map, Value};
use std::io::Read;

/// Sync batches may carry 1000 entities. Bound the inflated JSON as well, so
/// gzip keeps uploads small without bypassing the limit.
pub const JSON_LIMIT: usize = 8 * 1024 * 1024;
/// Express's default for URL-encoded forms.
pub const FORM_LIMIT: usize = 100 * 1024;

/// The parsed body, or None when the request is neither JSON nor a form.
pub struct JsonBody(pub Option<Value>);

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Json,
    Form,
}

impl<S: Send + Sync> FromRequest<S> for JsonBody {
    type Rejection = ApiError;

    async fn from_request(request: Request, _state: &S) -> Result<Self, Self::Rejection> {
        let headers = request.headers().clone();
        let content_type = header_text(&headers, header::CONTENT_TYPE).unwrap_or_default();
        let mut parameters = content_type.split(';');
        let kind = match parameters.next().unwrap_or_default().trim().to_ascii_lowercase().as_str() {
            "application/json" => Kind::Json,
            "application/x-www-form-urlencoded" => Kind::Form,
            _ => return Ok(Self(None)),
        };
        let charset = parameters
            .filter_map(|parameter| parameter.split_once('='))
            .find(|(name, _)| name.trim().eq_ignore_ascii_case("charset"))
            .map(|(_, value)| value.trim().trim_matches('"').to_ascii_lowercase());
        if let Some(charset) = charset
            && charset != "utf-8"
        {
            return Err(ApiError::Status(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                format!("unsupported charset \"{}\"", charset.to_ascii_uppercase()),
            ));
        }
        let encoding =
            header_text(&headers, header::CONTENT_ENCODING).unwrap_or("identity").trim().to_ascii_lowercase();
        if !matches!(encoding.as_str(), "identity" | "gzip" | "deflate" | "br") {
            return Err(ApiError::Status(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                format!("unsupported content encoding \"{encoding}\""),
            ));
        }
        let limit = if kind == Kind::Json { JSON_LIMIT } else { FORM_LIMIT };
        // A compressed body is never larger than its limit plus the framing of
        // a few incompressible blocks; the inflated size is checked below.
        let raw_limit = if encoding == "identity" { limit } else { limit + limit / 8 + 64 * 1024 };
        let raw = match Limited::new(request.into_body(), raw_limit).collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(error) if error.downcast_ref::<http_body_util::LengthLimitError>().is_some() => {
                return Err(too_large());
            }
            Err(error) => return Err(ApiError::status(400, format!("request aborted: {error}"))),
        };
        let mut bytes = inflate(&encoding, raw, limit)?;
        if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
            bytes.drain(..3);
        }
        if bytes.is_empty() {
            // Express leaves an empty body as an empty object.
            return Ok(Self(Some(Value::Object(Map::new()))));
        }
        match kind {
            Kind::Json => parse_json(&bytes).map(|value| Self(Some(value))),
            Kind::Form => Ok(Self(Some(parse_form(&bytes)))),
        }
    }
}

fn header_text(headers: &HeaderMap, name: header::HeaderName) -> Option<&str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

/// Express's strict mode accepts only objects and arrays; a syntax error is
/// a Bad Request.
fn parse_json(bytes: &[u8]) -> Result<Value, ApiError> {
    let first = bytes.iter().copied().find(|byte| !matches!(byte, b' ' | b'\t' | b'\n' | b'\r'));
    match first {
        None => return Err(ApiError::BadRequest("Unexpected end of JSON input".to_string())),
        Some(b'{' | b'[') => {}
        Some(byte) => {
            let token = char::from(byte);
            return Err(ApiError::BadRequest(format!("Unexpected token '{token}', \"{token}\"... is not valid JSON")));
        }
    }
    serde_json::from_slice(bytes).map_err(|error| ApiError::BadRequest(format!("Invalid JSON: {error}")))
}

/// `a=1&b=2` as an object of strings; a repeated key becomes an array.
fn parse_form(bytes: &[u8]) -> Value {
    let mut form = Map::new();
    for (key, value) in url::form_urlencoded::parse(bytes) {
        let value = Value::String(value.into_owned());
        match form.get_mut(key.as_ref()) {
            Some(Value::Array(values)) => values.push(value),
            Some(existing) => *existing = Value::Array(vec![existing.take(), value]),
            None => {
                form.insert(key.into_owned(), value);
            }
        }
    }
    Value::Object(form)
}

fn too_large() -> ApiError {
    ApiError::Status(StatusCode::PAYLOAD_TOO_LARGE, "request entity too large".to_string())
}

fn inflate(encoding: &str, raw: Bytes, limit: usize) -> Result<Vec<u8>, ApiError> {
    let reader: Box<dyn Read> = match encoding {
        "identity" => return Ok(raw.to_vec()),
        "gzip" => Box::new(flate2::read::MultiGzDecoder::new(&raw[..])),
        "deflate" => Box::new(flate2::read::ZlibDecoder::new(&raw[..])),
        _ => Box::new(brotli::Decompressor::new(&raw[..], 64 * 1024)),
    };
    let mut output = Vec::new();
    let read = reader
        .take(limit as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|error| ApiError::status(400, format!("invalid {encoding} body: {error}")))?;
    if read > limit {
        return Err(too_large());
    }
    Ok(output)
}
