//! String comparison as Swift does it. Swift's `==` and `<` compare strings by canonical equivalence: `"é"`
//! (U+00E9) equals `"e\u{301}"`, and order is the order of their NFC forms' scalars. The projections compare
//! titles and addresses this way, so a change of Unicode normalization alone is not an edit. Identities,
//! the keys of maps and sets, compare byte for byte.

use std::borrow::Cow;
use std::cmp::Ordering;

use icu_normalizer::ComposingNormalizerBorrowed;

fn nfc(text: &str) -> Cow<'_, str> {
    ComposingNormalizerBorrowed::new_nfc().normalize(text)
}

/// Swift's `==` on strings.
pub fn same(left: &str, right: &str) -> bool {
    left == right || (!(left.is_ascii() && right.is_ascii()) && nfc(left) == nfc(right))
}

/// Swift's `==` on optional strings.
pub fn same_option(left: Option<&str>, right: Option<&str>) -> bool {
    match (left, right) {
        (None, None) => true,
        (Some(left), Some(right)) => same(left, right),
        _ => false,
    }
}

/// Swift's `<` on strings, as an ordering.
pub fn order(left: &str, right: &str) -> Ordering {
    if left.is_ascii() && right.is_ascii() { left.cmp(right) } else { nfc(left).cmp(&nfc(right)) }
}

/// `left.utf16.lexicographicallyPrecedes(right.utf16)`, as an ordering.
pub fn order_utf16(left: &str, right: &str) -> Ordering {
    if left.is_ascii() && right.is_ascii() { left.cmp(right) } else { left.encode_utf16().cmp(right.encode_utf16()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_canonical_forms() {
        assert!(same("Caf\u{E9}", "Cafe\u{301}"));
        assert!(!same("Cafe", "Caf\u{E9}"));
        assert!(same_option(Some("\u{E9}"), Some("e\u{301}")));
        assert!(!same_option(None, Some("")));
        assert_eq!(order("e\u{301}", "\u{E9}"), Ordering::Equal);
        assert_eq!(order("a", "b"), Ordering::Less);
        // U+FF5E sorts after U+1F600 by UTF-16 code units, before it by scalars.
        assert_eq!(order("\u{FF5E}", "\u{1F600}"), Ordering::Less);
        assert_eq!(order_utf16("\u{FF5E}", "\u{1F600}"), Ordering::Greater);
    }
}
