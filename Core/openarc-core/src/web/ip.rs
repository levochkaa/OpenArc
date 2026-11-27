//! IP address text as Apple's Network framework reads it.

use std::net::Ipv6Addr;

/// One to four dot-separated parts: decimal (leading zeros stay decimal) or `0x` hexadecimal. Every part but
/// the last is a byte; the last fills the remaining bytes. A single part keeps its low 32 bits.
pub(crate) fn is_ipv4_address(text: &str) -> bool {
    let parts: Vec<&str> = text.split('.').collect();
    if parts.len() > 4 {
        return false;
    }
    let mut values = Vec::with_capacity(parts.len());
    for part in &parts {
        let Some(value) = part_value(part) else {
            return false;
        };
        values.push(value);
    }
    let (last, leading) = values.split_last().expect("split returns at least one part");
    if leading.is_empty() {
        return true;
    }
    let remaining_bits = 8 * (4 - leading.len() as u32);
    leading.iter().all(|&value| value <= 0xFF) && *last < 1u64 << remaining_bits
}

/// The part's value, saturating at `u64::MAX` as `strtoul` does.
fn part_value(part: &str) -> Option<u64> {
    let (digits, radix) = match part.strip_prefix("0x").or_else(|| part.strip_prefix("0X")) {
        Some(hex) => (hex, 16),
        None => (part, 10),
    };
    if digits.is_empty() || !digits.chars().all(|character| character.is_digit(radix)) {
        return None;
    }
    Some(digits.chars().fold(0u64, |value, character| {
        value.saturating_mul(radix as u64).saturating_add(character.to_digit(radix).unwrap_or(0) as u64)
    }))
}

/// An IPv6 address, optionally followed by a "%" and a zone that contains no further "%".
pub(crate) fn is_ipv6_address(text: &str) -> bool {
    let (address, zone) = match text.split_once('%') {
        Some((address, zone)) => (address, Some(zone)),
        None => (text, None),
    };
    zone.is_none_or(|zone| !zone.contains('%')) && address.parse::<Ipv6Addr>().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_ipv4_shorthand() {
        for text in
            ["127.0.0.1", "127.1", "1.2.3", "1", "4294967296", "99999999999", "0x7f.1", "0177.0.0.1", "1.2.65535"]
        {
            assert!(is_ipv4_address(text), "{text}");
        }
        for text in
            ["1.2.3.4.", "1.2.3.4.5", "256.1.1.1", "1.2.65536", " 1.2.3.4", "1..2.3", "", "0x", "0xg", "1e3", "+1"]
        {
            assert!(!is_ipv4_address(text), "{text}");
        }
    }

    #[test]
    fn reads_ipv6_with_a_zone() {
        for text in ["::1", "::", "fe80::1%en0", "fe80::1%", "::ffff:1.2.3.4", "1:2:3:4:5:6:7::"] {
            assert!(is_ipv6_address(text), "{text}");
        }
        for text in ["[::1]", "::ffff:1.2.3", "fe80::1%en0%", "1::2::3", "::1 "] {
            assert!(!is_ipv6_address(text), "{text}");
        }
    }
}
