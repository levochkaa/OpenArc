//! What the address bar does with typed text: open it as an address or search for it.

use super::components::UrlComponents;
use super::domain::parse_host;
use super::internal_urls::canonical_internal_url;
use super::ip::{is_ipv4_address, is_ipv6_address};
use super::search_engine::{CoreSearchEngine, search_url};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreNavigationKind {
    Url,
    Search,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreNavigationResolution {
    pub kind: CoreNavigationKind,
    /// The text as typed, trimmed.
    pub display_text: String,
    /// The address to load: the typed address, or the search engine's results page.
    pub resolved_url: String,
}

/// The address to open for typed text, or `None` when the text is blank. Text that is not an address is
/// searched with `search_engine`.
#[uniffi::export(name = "core_resolve_navigation")]
pub fn resolve_navigation(input: String, search_engine: CoreSearchEngine) -> Option<CoreNavigationResolution> {
    let trimmed = super::trimmed(&input);
    if trimmed.is_empty() {
        return None;
    }
    let display_text = trimmed.to_owned();
    if let Some(resolved_url) = resolved_url(trimmed) {
        return Some(CoreNavigationResolution { kind: CoreNavigationKind::Url, display_text, resolved_url });
    }
    Some(CoreNavigationResolution {
        kind: CoreNavigationKind::Search,
        resolved_url: search_url(search_engine, display_text.clone()),
        display_text,
    })
}

/// Hosts that only make sense on this machine or network: localhost, any `.localhost` or `.local` name, and
/// IP addresses.
#[uniffi::export(name = "core_is_local_host")]
pub fn is_local_host(host: String) -> bool {
    let lowered = host.to_lowercase();
    let lowered = lowered.trim_matches(|character| character == '[' || character == ']');
    lowered == "localhost"
        || lowered.ends_with(".localhost")
        || lowered.ends_with(".local")
        || is_ipv4_address(lowered)
        || is_ipv6_address(lowered)
}

fn resolved_url(input: &str) -> Option<String> {
    if let Some(internal) = canonical_internal_url(input.to_owned()) {
        return Some(internal);
    }
    if has_explicit_scheme(input) {
        let components = UrlComponents::parse(input)?;
        let scheme = components.scheme()?.to_lowercase();
        if scheme.is_empty() || !is_valid_resolved_url(&components, &scheme, true) {
            return None;
        }
        return components.string();
    }

    let mut components = UrlComponents::parse(&format!("https://{input}"))?;
    if !is_valid_resolved_url(&components, "https", false) {
        return None;
    }
    // Local servers rarely have a certificate, so typed local addresses use plain http, as other browsers do.
    if components.host().is_some_and(is_local_host) {
        components.set_scheme("http");
    }
    components.string()
}

fn has_explicit_scheme(input: &str) -> bool {
    let Some((candidate, remainder)) = input.split_once(':') else {
        return false;
    };
    let mut characters = candidate.chars();
    let starts_with_letter = characters.next().is_some_and(|first| first.is_ascii_alphabetic());
    if !starts_with_letter || !characters.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')) {
        return false;
    }
    !is_likely_bare_host_port(candidate, remainder)
}

/// `localhost:3000` and `example.com:8080` are a host and a port, not a scheme.
fn is_likely_bare_host_port(candidate: &str, remainder: &str) -> bool {
    remainder.chars().next().is_some_and(char::is_numeric)
        && (candidate.eq_ignore_ascii_case("localhost") || candidate.contains('.'))
}

fn is_valid_resolved_url(components: &UrlComponents, scheme: &str, allow_single_label_host: bool) -> bool {
    if components.string().is_none() {
        return false;
    }
    if scheme != "http" && scheme != "https" {
        return true;
    }
    components.host().is_some_and(|host| is_valid_web_host(&host, allow_single_label_host))
}

fn is_valid_web_host(host: &str, allow_single_label_host: bool) -> bool {
    if host.is_empty() {
        return false;
    }
    // localhost, `.localhost` and `.local` names and IP addresses are real hosts though no public suffix
    // lists them.
    if is_local_host(host.to_owned()) {
        return true;
    }
    if host.ends_with('.') {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if (!allow_single_label_host && labels.len() < 2) || !labels.iter().all(|label| is_valid_domain_label(label)) {
        return false;
    }
    if labels.len() == 1 {
        return true;
    }
    parse_host(host.to_owned())
        .is_some_and(|parsed| parsed.registrable_domain.is_some() || parsed.public_suffix.eq_ignore_ascii_case(host))
}

fn is_valid_domain_label(label: &str) -> bool {
    let bytes = label.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 63
        && bytes[0].is_ascii_alphanumeric()
        && bytes[bytes.len() - 1].is_ascii_alphanumeric()
        && bytes.iter().all(|&byte| byte.is_ascii_alphanumeric() || byte == b'-')
}
