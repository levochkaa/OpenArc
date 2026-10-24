//! Sparkle appcasts, release downloads and the public release index, proxied
//! from GitHub Releases.

use crate::config::{Config, js_number};
use crate::error::{ApiError, ApiResult};
use axum::http::HeaderMap;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

pub const GITHUB_API_URL: &str = "https://api.github.com";

#[derive(Clone, Debug, Deserialize)]
pub struct ReleaseAsset {
    pub id: i64,
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub content_type: Option<String>,
    #[serde(default)]
    pub size: Option<i64>,
    #[serde(default)]
    pub download_count: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
struct Release {
    id: i64,
    tag_name: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    body: Option<String>,
    html_url: String,
    draft: bool,
    prerelease: bool,
    created_at: String,
    #[serde(default)]
    published_at: Option<String>,
    #[serde(default)]
    assets: Vec<ReleaseAsset>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Channel {
    Stable,
    Beta,
}

impl Channel {
    fn name(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Beta => "beta",
        }
    }
}

pub struct Download {
    pub asset: ReleaseAsset,
    pub response: reqwest::Response,
}

#[derive(Clone)]
pub struct UpdatesService {
    http: reqwest::Client,
    config: Arc<Config>,
    api_url: String,
}

impl UpdatesService {
    pub fn new(config: Arc<Config>, http: reqwest::Client, api_url: &str) -> Self {
        Self { http, config, api_url: api_url.trim_end_matches('/').to_string() }
    }

    pub async fn sparkle_appcast(&self, channel: Channel) -> ApiResult<String> {
        let release = self.latest_release(channel).await?;
        let name = &self.config.update_appcast_asset;
        let asset = release.assets.iter().find(|asset| &asset.name == name).cloned().ok_or_else(|| {
            ApiError::status(404, format!("Release asset '{name}' was not found in {}", release.tag_name))
        })?;
        let response = self.fetch_asset(&asset).await?;
        Ok(response.text().await?)
    }

    pub async fn sparkle_download(&self, asset_name: &str) -> ApiResult<Download> {
        let releases = public_releases(self.fetch_releases().await?);
        let asset = releases
            .iter()
            .find_map(|release| release.assets.iter().find(|asset| asset.name == asset_name))
            .cloned()
            .ok_or_else(|| ApiError::status(404, format!("Release asset '{asset_name}' was not found")))?;
        self.download(asset).await
    }

    pub async fn release_asset_download(&self, asset_id: &str, asset_name: &str) -> ApiResult<Download> {
        if asset_id.is_empty() || !asset_id.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(ApiError::status(400, "Invalid release asset id"));
        }
        let repository = self.repository()?;
        let response = self
            .github(
                &format!("{}/repos/{repository}/releases/assets/{asset_id}", self.api_url),
                "application/vnd.github+json",
            )
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            return Err(ApiError::status(status, format!("GitHub release asset lookup failed with {status}")));
        }
        let asset: ReleaseAsset = response.json().await?;
        // A mismatched name never fetches the asset body.
        if asset.name != asset_name {
            return Err(ApiError::status(404, format!("Release asset '{asset_name}' was not found")));
        }
        self.download(asset).await
    }

    pub async fn release_index(
        &self,
        channel: Option<&str>,
        limit: Option<&str>,
        headers: &HeaderMap,
    ) -> ApiResult<Value> {
        let channel = match channel.unwrap_or("all") {
            "all" => None,
            other => Some(parse_channel(other)?),
        };
        let limit = match limit {
            None | Some("") => 20,
            Some(text) => match js_number(text) {
                Some(value) if value.fract() == 0.0 && (1.0..=100.0).contains(&value) => value as usize,
                _ => return Err(ApiError::status(400, "Release limit must be an integer from 1 to 100")),
            },
        };
        let releases = public_releases(self.fetch_releases().await?);
        let latest_stable = releases.iter().find(|release| !release.prerelease).map(|release| release.id);
        let base_url = self.public_base_url(headers);
        let serialized: Vec<Value> = releases
            .iter()
            .filter(|release| channel.is_none_or(|channel| release_channel(release) == channel))
            .take(limit)
            .map(|release| serialize_release(release, &base_url, latest_stable))
            .collect();
        Ok(json!({"releases": serialized}))
    }

    async fn latest_release(&self, channel: Channel) -> ApiResult<Release> {
        public_releases(self.fetch_releases().await?)
            .into_iter()
            .find(|release| release_channel(release) == channel)
            .ok_or_else(|| ApiError::status(404, format!("No {} release was found", channel.name())))
    }

    async fn fetch_releases(&self) -> ApiResult<Vec<Release>> {
        let repository = self.repository()?;
        let response = self
            .github(
                &format!("{}/repos/{repository}/releases?per_page=100", self.api_url),
                "application/vnd.github+json",
            )
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            return Err(ApiError::status(status, format!("GitHub releases lookup failed with {status}")));
        }
        Ok(response.json().await?)
    }

    async fn download(&self, asset: ReleaseAsset) -> ApiResult<Download> {
        let response = self.fetch_asset(&asset).await?;
        Ok(Download { asset, response })
    }

    async fn fetch_asset(&self, asset: &ReleaseAsset) -> ApiResult<reqwest::Response> {
        let response = self.github(&asset.url, "application/octet-stream").send().await?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            return Err(ApiError::status(status, format!("GitHub asset download failed with {status}")));
        }
        Ok(response)
    }

    fn repository(&self) -> ApiResult<&str> {
        self.config
            .github_release_repository
            .as_deref()
            .filter(|repository| !repository.is_empty())
            .ok_or_else(|| ApiError::status(503, "GITHUB_RELEASE_REPOSITORY is not configured"))
    }

    fn github(&self, url: &str, accept: &str) -> reqwest::RequestBuilder {
        let mut request = self
            .http
            .get(url)
            .header("Accept", accept)
            .header("User-Agent", "TheBrowser Update Server")
            .header("X-GitHub-Api-Version", "2026-03-10");
        if !self.config.github_release_token.is_empty() {
            request = request.bearer_auth(&self.config.github_release_token);
        }
        request
    }

    fn public_base_url(&self, headers: &HeaderMap) -> String {
        if let Some(url) = &self.config.public_base_url {
            return url.clone();
        }
        let first = |name: &str| {
            headers
                .get(name)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.split(',').next())
                .map(|value| value.trim().to_string())
        };
        let host = first("x-forwarded-host")
            .or_else(|| headers.get("host").and_then(|value| value.to_str().ok()).map(str::to_string))
            .unwrap_or_else(|| format!("{}:{}", self.config.host, self.config.port));
        let protocol = first("x-forwarded-proto").unwrap_or_else(|| {
            if host.starts_with("localhost") || host.starts_with("127.0.0.1") { "http" } else { "https" }.to_string()
        });
        format!("{protocol}://{host}")
    }
}

pub fn parse_channel(value: &str) -> ApiResult<Channel> {
    match value {
        "stable" => Ok(Channel::Stable),
        "beta" => Ok(Channel::Beta),
        _ => Err(ApiError::status(400, "Release channel must be stable or beta")),
    }
}

/// `attachment` with the asset name, without quotes or line breaks that could
/// end the header.
pub fn content_disposition(asset_name: &str) -> String {
    let name: String = asset_name.chars().filter(|character| !matches!(character, '"' | '\r' | '\n')).collect();
    format!("attachment; filename=\"{name}\"")
}

fn release_channel(release: &Release) -> Channel {
    if release.prerelease { Channel::Beta } else { Channel::Stable }
}

/// Published releases, newest first.
fn public_releases(releases: Vec<Release>) -> Vec<Release> {
    let mut releases: Vec<Release> = releases.into_iter().filter(|release| !release.draft).collect();
    let date = |release: &Release| {
        let text = release.published_at.as_deref().unwrap_or(&release.created_at);
        chrono::DateTime::parse_from_rfc3339(text).map(|date| date.timestamp_millis()).unwrap_or(i64::MIN)
    };
    releases.sort_by_key(|release| std::cmp::Reverse(date(release)));
    releases
}

fn serialize_release(release: &Release, base_url: &str, latest_stable: Option<i64>) -> Value {
    let name = release.name.as_deref().map(str::trim).filter(|name| !name.is_empty()).unwrap_or(&release.tag_name);
    let published = release.published_at.as_deref().unwrap_or(&release.created_at);
    let assets: Vec<Value> = release
        .assets
        .iter()
        .filter(|asset| {
            let name = asset.name.to_lowercase();
            !name.ends_with(".xml") && !name.ends_with(".md") && !name.ends_with(".delta")
        })
        .map(|asset| {
            let path = format!("/v1/releases/assets/{}/{}", asset.id, encode_uri_component(&asset.name));
            let download_url = url::Url::parse(base_url)
                .and_then(|base| base.join(&path))
                .map(|url| url.to_string())
                .unwrap_or_else(|_| format!("{}{path}", base_url.trim_end_matches('/')));
            json!({
                "id": asset.id,
                "name": asset.name,
                "contentType": asset.content_type.as_deref().unwrap_or("application/octet-stream"),
                "size": asset.size,
                "downloadCount": asset.download_count,
                "downloadURL": download_url,
            })
        })
        .collect();
    json!({
        "id": release.id,
        "tagName": release.tag_name,
        "name": name,
        "channel": release_channel(release).name(),
        "isLatestStable": Some(release.id) == latest_stable,
        "publishedAt": if published.is_empty() { Value::Null } else { json!(published) },
        "htmlURL": release.html_url,
        "notes": release.body.as_deref().unwrap_or(""),
        "assets": assets,
    })
}

/// JavaScript's `encodeURIComponent`.
fn encode_uri_component(text: &str) -> String {
    let mut output = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
            output.push(byte as char);
        } else {
            output.push_str(&format!("%{byte:02X}"));
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_normal_filenames_in_content_disposition() {
        assert_eq!(content_disposition("TheBrowser-1.2.3.dmg"), "attachment; filename=\"TheBrowser-1.2.3.dmg\"");
    }

    #[test]
    fn removes_header_injection_characters_from_content_disposition_filenames() {
        let header = content_disposition("TheBrowser\r\nX-Injected: yes \"Beta\".dmg");
        assert_eq!(header, "attachment; filename=\"TheBrowserX-Injected: yes Beta.dmg\"");
        assert!(!header.contains(['\r', '\n']));
    }

    #[test]
    fn encodes_asset_names_like_encode_uri_component() {
        assert_eq!(encode_uri_component("The Browser (1).dmg"), "The%20Browser%20(1).dmg");
        assert_eq!(encode_uri_component("ü/?#"), "%C3%BC%2F%3F%23");
    }
}
