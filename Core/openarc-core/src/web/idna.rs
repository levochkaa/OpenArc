//! Host IDNA encoding and decoding with Apple Foundation's UTS 46 options: nontransitional processing,
//! bidi and joiner checks, no STD3 rules. A result that differs from the host only in ASCII case returns
//! the host as given, so typed capitals survive.

use idna::uts46::{AsciiDenyList, DnsLength, Hyphens, Uts46};

/// The ASCII (Punycode) form of `host`, or `None` when it is not a valid domain name.
pub(crate) fn encode(host: &str) -> Option<String> {
    if host.is_empty() {
        return Some(String::new());
    }
    let encoded = Uts46::new()
        .to_ascii(host.as_bytes(), AsciiDenyList::EMPTY, Hyphens::Check, DnsLength::VerifyAllowRootDot)
        .ok()?;
    Some(keeping_case(host, &encoded))
}

/// The Unicode form of `host`. Empty labels, label lengths and hyphen positions are not errors here.
pub(crate) fn decode(host: &str) -> Option<String> {
    if host.is_empty() {
        return Some(String::new());
    }
    let (decoded, result) = Uts46::new().to_unicode(host.as_bytes(), AsciiDenyList::EMPTY, Hyphens::Allow);
    result.ok()?;
    Some(keeping_case(host, &decoded))
}

fn keeping_case(original: &str, converted: &str) -> String {
    let same = original.len() == converted.len()
        && original.bytes().zip(converted.bytes()).all(|(a, b)| a == b || a.to_ascii_lowercase() == b);
    if same { original.to_owned() } else { converted.to_owned() }
}
