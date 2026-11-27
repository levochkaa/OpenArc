//! How the toolbar and the sidebar show an address.

use super::components::UrlComponents;
use super::ip::{is_ipv4_address, is_ipv6_address};
use super::{trimmed, without_www};

/// The short form of an address, such as `example.com` or `localhost:3000`, or `None` for a blank address
/// (the app shows its new tab title).
#[uniffi::export(name = "core_url_display_string")]
pub fn url_display_string(url: String) -> Option<String> {
    let trimmed = trimmed(&url);
    if trimmed.is_empty() {
        return None;
    }
    let Some(components) = UrlComponents::parse(trimmed) else {
        return Some(without_www(trimmed).to_owned());
    };
    let scheme = components.scheme().map(|scheme| scheme.to_lowercase());
    let host = components.host().filter(|host| !host.is_empty());
    let (Some(scheme), Some(host)) = (scheme, host) else {
        return Some(without_www(trimmed).to_owned());
    };
    if scheme != "http" && scheme != "https" {
        return Some(without_www(trimmed).to_owned());
    }
    let display_host = without_www(&host);
    if let Some(port) = components.port()
        && should_display_port(port, &scheme, display_host)
    {
        let host = ipv6_address_host(display_host).map_or_else(|| display_host.to_owned(), |ipv6| format!("[{ipv6}]"));
        return Some(format!("{host}:{port}"));
    }
    Some(display_host.to_owned())
}

/// The whole address with a leading `www.` left out of the host, or `None` for a blank address.
#[uniffi::export(name = "core_url_full_display_string")]
pub fn url_full_display_string(url: String) -> Option<String> {
    let trimmed = trimmed(&url);
    if trimmed.is_empty() {
        return None;
    }
    let Some(mut components) = UrlComponents::parse(trimmed) else {
        return Some(without_www(trimmed).to_owned());
    };
    let Some(host) = components.host().filter(|host| !host.is_empty()) else {
        return Some(without_www(trimmed).to_owned());
    };
    let display_host = without_www(&host).to_owned();
    if display_host == host {
        return Some(trimmed.to_owned());
    }
    components.set_host(Some(&display_host));
    Some(components.string().unwrap_or_else(|| trimmed.to_owned()))
}

/// The host without a leading `www.`.
#[uniffi::export(name = "core_host_display_string")]
pub fn host_display_string(host: String) -> String {
    without_www(&host).to_owned()
}

fn should_display_port(port: i64, scheme: &str, host: &str) -> bool {
    let is_local = host.eq_ignore_ascii_case("localhost") || is_ipv4_address(host) || ipv6_address_host(host).is_some();
    is_local
        || match scheme {
            "http" => port != 80,
            "https" => port != 443,
            _ => false,
        }
}

fn ipv6_address_host(host: &str) -> Option<&str> {
    let unbracketed = host.strip_prefix('[').and_then(|host| host.strip_suffix(']')).unwrap_or(host);
    is_ipv6_address(unbracketed).then_some(unbracketed)
}
