//! OpenArc's internal pages. They live at `openarc://` addresses; `chrome://`, `arc://` and `dia://` are
//! aliases, and the Chromium engines load Chromium's pages at `chrome://`.

use super::components::UrlComponents;

pub const CANONICAL_SCHEME: &str = "openarc";
pub const CHROMIUM_SCHEME: &str = "chrome";
const ALIAS_SCHEMES: &[&str] = &[CANONICAL_SCHEME, CHROMIUM_SCHEME, "arc", "dia"];

const SETTINGS_HOST: &str = "settings";
const EXTENSIONS_HOST: &str = "extensions";
const BOOKMARKS_HOST: &str = "bookmarks";
const PASSWORD_MANAGER_HOST: &str = "password-manager";
pub const CREDITS_HOST: &str = "credits";
/// Easels: the engine shows an empty page there and the window draws the canvas.
pub const EASEL_HOST: &str = "easel";
/// Notes open at openarc://notes/<id>; the window draws the note over an empty page.
pub const NOTES_HOST: &str = "notes";
/// Hosts the app serves itself rather than Chromium's internal pages.
const APP_SERVED_HOSTS: &[&str] = &[CREDITS_HOST, EASEL_HOST, NOTES_HOST];

const CREDITS_URL: &str = "openarc://credits/";
const CHROMIUM_CREDITS_URL: &str = "chrome://credits/";

fn is_app_served(host: &str) -> bool {
    APP_SERVED_HOSTS.contains(&host)
}

/// openarc://passwords and openarc://settings/passwords are the password manager: Chromium has no page at the
/// first and shows its settings' first page for the second.
fn is_passwords_shortcut(host: &str, path: &str) -> bool {
    let path = path.to_lowercase();
    match host {
        "passwords" => path.is_empty() || path == "/",
        SETTINGS_HOST => path == "/passwords" || path == "/passwords/",
        _ => false,
    }
}

fn prefers_root_path(host: &str) -> bool {
    matches!(host, BOOKMARKS_HOST | EXTENSIONS_HOST | SETTINGS_HOST)
}

/// The scheme, lowercased, and the components of `url`.
fn components_with_scheme(url: &str) -> Option<(String, UrlComponents)> {
    let components = UrlComponents::parse(url)?;
    Some((components.scheme()?.to_lowercase(), components))
}

/// The `openarc://` address of an internal page typed or loaded under any alias, or `None` for any other
/// address and for the pages the app serves itself.
#[uniffi::export(name = "core_canonical_internal_url")]
pub fn canonical_internal_url(url: String) -> Option<String> {
    let trimmed = super::trimmed(&url);
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("about:settings") {
        return Some("openarc://settings/".to_owned());
    }
    if trimmed.eq_ignore_ascii_case("about:bookmarks") {
        return Some("openarc://bookmarks/".to_owned());
    }
    let (scheme, mut components) = components_with_scheme(trimmed)?;
    if !ALIAS_SCHEMES.contains(&scheme.as_str()) {
        return None;
    }
    let host = components.host()?.to_lowercase();
    if host.is_empty() || is_app_served(&host) {
        return None;
    }
    components.set_scheme(CANONICAL_SCHEME);
    components.set_host(Some(&host));
    if is_passwords_shortcut(&host, &components.path()) {
        components.set_host(Some(PASSWORD_MANAGER_HOST));
        components.set_path("/passwords");
    }
    if components.path().is_empty() && prefers_root_path(&host) {
        components.set_path("/");
    }
    components.string()
}

/// The `chrome://` address Chromium loads for a canonical `openarc://` address.
#[uniffi::export(name = "core_chromium_internal_url")]
pub fn chromium_internal_url(canonical_url: String) -> Option<String> {
    let (scheme, mut components) = components_with_scheme(&canonical_url)?;
    if scheme != CANONICAL_SCHEME {
        return None;
    }
    let host = components.host()?.to_lowercase();
    if host.is_empty() || is_app_served(&host) {
        return None;
    }
    components.set_scheme(CHROMIUM_SCHEME);
    components.set_host(Some(&host));
    if components.path().is_empty() && prefers_root_path(&host) {
        components.set_path("/");
    }
    components.string()
}

/// The internal page's host, such as `settings`, for an internal address under any alias.
#[uniffi::export(name = "core_internal_url_host")]
pub fn internal_url_host(url: String) -> Option<String> {
    let canonical = canonical_internal_url(url.clone()).or_else(|| already_canonical(&url))?;
    UrlComponents::parse(&canonical)?.host().map(|host| host.to_lowercase())
}

fn already_canonical(url: &str) -> Option<String> {
    let (scheme, components) = components_with_scheme(url)?;
    let host = components.host()?;
    (scheme == CANONICAL_SCHEME && !host.is_empty() && !is_app_served(&host.to_lowercase()))
        .then(|| components.string())
        .flatten()
}

fn host_with_scheme(url: &str, scheme: &str) -> Option<String> {
    let (url_scheme, components) = components_with_scheme(url)?;
    (url_scheme == scheme).then(|| components.host().map(|host| host.to_lowercase())).flatten()
}

/// The address a Chrome engine page loads for `url`. On Chrome's engine, `openarc://` addresses of
/// Chromium's pages load Chromium's own page; openarc://credits is the engine's chrome://credits. The engine
/// serves OpenArc's other addresses (Easels, notes) itself.
#[uniffi::export(name = "core_chrome_engine_load_url")]
pub fn chrome_engine_load_url(url: String) -> String {
    if host_with_scheme(&url, CANONICAL_SCHEME).as_deref() == Some(CREDITS_HOST) {
        return CHROMIUM_CREDITS_URL.to_owned();
    }
    chromium_internal_url(url.clone()).unwrap_or(url)
}

/// The address a Chrome engine page shows for the `url` it committed: `chrome://` pages show under
/// `openarc://` again, as CEF's tabs do.
#[uniffi::export(name = "core_chrome_engine_display_url")]
pub fn chrome_engine_display_url(url: String) -> String {
    match host_with_scheme(&url, CHROMIUM_SCHEME).as_deref() {
        None => url,
        Some(CREDITS_HOST) => CREDITS_URL.to_owned(),
        Some(_) => canonical_internal_url(url.clone()).unwrap_or(url),
    }
}
