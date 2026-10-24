//! HTTP errors with the response bodies existing clients already read.

use crate::js_json;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

#[derive(Debug)]
pub enum ApiError {
    /// Request validation: `{statusCode: 400, error: "Bad Request", message}`.
    BadRequest(String),
    /// Missing or invalid bearer token: `{error: "unauthorized"}`.
    Unauthorized,
    Forbidden(String),
    /// Clients match these messages, for example the bootstrap requirement.
    Conflict(String),
    /// A status with a plain message: `{statusCode, message}`.
    Status(StatusCode, String),
    /// An unmatched route.
    RouteNotFound {
        method: String,
        path: String,
    },
    Internal(anyhow::Error),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn status(code: u16, message: impl Into<String>) -> Self {
        Self::Status(StatusCode::from_u16(code).unwrap_or(StatusCode::BAD_GATEWAY), message.into())
    }

    fn parts(&self) -> (StatusCode, Value) {
        match self {
            Self::BadRequest(message) => {
                (StatusCode::BAD_REQUEST, json!({"statusCode": 400, "error": "Bad Request", "message": message}))
            }
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, json!({"error": "unauthorized"})),
            Self::Forbidden(message) => {
                (StatusCode::FORBIDDEN, json!({"message": message, "error": "Forbidden", "statusCode": 403}))
            }
            Self::Conflict(message) => {
                (StatusCode::CONFLICT, json!({"message": message, "error": "Conflict", "statusCode": 409}))
            }
            Self::Status(status, message) => (*status, json!({"statusCode": status.as_u16(), "message": message})),
            Self::RouteNotFound { method, path } => (
                StatusCode::NOT_FOUND,
                json!({"message": format!("Cannot {method} {path}"), "error": "Not Found", "statusCode": 404}),
            ),
            Self::Internal(_) => {
                (StatusCode::INTERNAL_SERVER_ERROR, json!({"statusCode": 500, "message": "Internal server error"}))
            }
        }
    }
}

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(error: E) -> Self {
        Self::Internal(error.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        if let Self::Internal(error) = &self {
            tracing::error!(error = format!("{error:#}"), "request failed");
        }
        let (status, body) = self.parts();
        json_response(status, &body)
    }
}

/// A JSON response written as `JSON.stringify` would write it.
pub fn json_response(status: StatusCode, body: &Value) -> Response {
    let mut response = (status, js_json::stringify(body)).into_response();
    response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json; charset=utf-8"));
    response
}
