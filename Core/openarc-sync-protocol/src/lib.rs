//! Constants of OpenArc's sync protocol. The server (`Backend`) and every client read them from here, so both
//! sides agree on versions and limits. `docs/sync-protocol.md` describes the protocol.

/// Push protocol versions the server accepts and every client may send.
pub const SUPPORTED_PUSH_VERSIONS: [u8; 5] = [2, 3, 4, 5, 6];

/// Where a tab lives: a Space's unpinned list, its pinned list, or a web app.
pub const PLACEMENTS: [&str; 3] = ["temporary", "spacePinned", "app"];

/// Changes or operations one push carries at most (v1–v4, v6), and items one move carries at most.
pub const BATCH_LIMIT: usize = 1000;
/// Expiry operations one v5 push carries at most.
pub const EXPIRY_BATCH_LIMIT: usize = 100;
/// Inflated JSON request bodies are bounded, so gzip keeps uploads small without bypassing the limit.
pub const JSON_BODY_LIMIT: usize = 8 * 1024 * 1024;
/// v5 acknowledgements are bounded more tightly than other responses.
pub const EXPIRY_RESPONSE_LIMIT: usize = 4 * 1024 * 1024;
/// Pull pages carry at most this many events; a pull without a limit gets `DEFAULT_PULL_LIMIT`.
pub const PULL_LIMIT: usize = 1000;
pub const DEFAULT_PULL_LIMIT: usize = 500;

/// Inactivity intervals automatic expiry may use: 12 hours, a day, three days, a week, 30 days.
pub const EXPIRY_INTERVALS: [u64; 5] = [43_200, 86_400, 259_200, 604_800, 2_592_000];

/// Boost limits, in UTF-16 code units as JavaScript counts string length.
pub const BOOST_HOST_LIMIT: usize = 253;
pub const BOOST_CODE_LIMIT: usize = 262_144;
pub const BOOST_SELECTOR_LIMIT: usize = 4096;
pub const BOOST_SELECTOR_COUNT_LIMIT: usize = 1000;
pub const BOOST_TITLE_LIMIT: usize = 1024;
pub const BOOST_FONT_FAMILY_LIMIT: usize = 256;
pub const BOOST_TEXT_CASES: [&str; 3] = ["capitalize", "uppercase", "lowercase"];

/// Whether automatic expiry may use `seconds` as its inactivity interval.
pub fn is_expiry_interval(seconds: u64) -> bool {
    EXPIRY_INTERVALS.contains(&seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_only_the_listed_expiry_intervals() {
        assert!(EXPIRY_INTERVALS.iter().all(|&seconds| is_expiry_interval(seconds)));
        assert!(!is_expiry_interval(3600));
    }
}
