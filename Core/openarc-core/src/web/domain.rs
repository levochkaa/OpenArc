//! Public suffixes and registrable domains from the Public Suffix List, ICANN and private sections.

/// A host's public suffix and, below it, the registrable domain (`example.co.uk` for `www.example.co.uk`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreParsedHost {
    pub public_suffix: String,
    /// `None` when the host is itself a public suffix.
    pub registrable_domain: Option<String>,
}

/// The host's suffix and registrable domain, or `None` for a single label, an empty label, or a last label no
/// rule of the list matches.
#[uniffi::export(name = "core_parse_host")]
pub fn parse_host(host: String) -> Option<CoreParsedHost> {
    let host = host.to_lowercase();
    let host = host.strip_suffix('.').unwrap_or(&host);
    if !host.contains('.') || host.split('.').any(str::is_empty) {
        return None;
    }
    let suffix = psl::suffix(host.as_bytes()).filter(psl::Suffix::is_known)?;
    let public_suffix = String::from_utf8(suffix.as_bytes().to_vec()).ok()?;
    let registrable_domain =
        psl::domain(host.as_bytes()).and_then(|domain| String::from_utf8(domain.as_bytes().to_vec()).ok());
    Some(CoreParsedHost { public_suffix, registrable_domain })
}

/// The site a host belongs to: its registrable domain, or the host itself when the list has none.
#[uniffi::export(name = "core_registrable_domain")]
pub fn registrable_domain(host: String) -> String {
    parse_host(host.clone()).and_then(|parsed| parsed.registrable_domain).unwrap_or(host)
}
