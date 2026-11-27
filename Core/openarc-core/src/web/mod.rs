//! Web addresses: what the address bar does with typed text, internal pages, search engines, how an
//! address is shown and shared.

mod components;
pub mod display;
pub mod domain;
mod idna;
pub mod internal_urls;
mod ip;
pub mod navigation;
pub mod search_engine;
pub mod tracking;

/// Unicode whitespace and newlines, as Foundation's `CharacterSet.whitespacesAndNewlines` has them.
fn trimmed(text: &str) -> &str {
    text.trim()
}

/// The text without its first `count` characters, as Swift's `dropFirst`.
fn dropping_first(text: &str, count: usize) -> &str {
    text.char_indices().nth(count).map_or("", |(index, _)| &text[index..])
}

/// `www.example.com` is shown as `example.com`; `www.` alone and `www.x` with nothing after the prefix stay.
fn without_www(text: &str) -> &str {
    if text.chars().count() > 4 && text.get(..4).is_some_and(|prefix| prefix.eq_ignore_ascii_case("www.")) {
        dropping_first(text, 4)
    } else {
        text
    }
}
