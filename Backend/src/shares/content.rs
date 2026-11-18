//! What a share may hold, checked and cleaned before it is stored. The
//! request schema has already checked types and lengths.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// Folders inside folders, at most this deep.
pub const MAX_FOLDER_DEPTH: usize = 8;
/// A favicon or Space icon as PNG bytes, at most this large.
pub const MAX_IMAGE_BYTES: usize = 12 * 1024;
/// The stored content, at most this large.
pub const MAX_CONTENT_BYTES: usize = 2 * 1024 * 1024;
const PNG_PREFIX: &str = "data:image/png;base64,";
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Space,
    Folder,
    Quote,
}

impl Kind {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "space" => Some(Self::Space),
            "folder" => Some(Self::Folder),
            "quote" => Some(Self::Quote),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Space => "space",
            Self::Folder => "folder",
            Self::Quote => "quote",
        }
    }

    /// The page's path segment: `/s/` for tabs, `/q/` for quotes.
    pub fn path(self) -> &'static str {
        match self {
            Self::Space | Self::Folder => "s",
            Self::Quote => "q",
        }
    }
}

/// A share ready to store.
#[derive(Debug, PartialEq)]
pub struct Normalized {
    pub kind: Kind,
    pub source_id: String,
    pub title: String,
    pub excerpt: Option<String>,
    pub item_count: i32,
    pub content: Value,
}

/// Checks a parsed publish request and returns what to store, or why not.
pub fn normalize(request: &Value) -> Result<Normalized, String> {
    let kind = Kind::parse(text(request, "kind").unwrap_or_default()).ok_or("kind: Invalid option")?;
    let normalized = match kind {
        Kind::Quote => quote(request)?,
        Kind::Space | Kind::Folder => collection(kind, request)?,
    };
    if normalized.content.to_string().len() > MAX_CONTENT_BYTES {
        return Err("body: Shared content is too large".to_string());
    }
    Ok(normalized)
}

fn collection(kind: Kind, request: &Value) -> Result<Normalized, String> {
    let title = line(text(request, "title")).ok_or("title: Required")?;
    let mut content = Map::new();
    content.insert("title".to_string(), json!(title));
    if let Some(icon) = text(request, "icon") {
        content.insert("icon".to_string(), json!(icon_name(icon).ok_or("icon: Invalid icon")?));
    }
    if let Some(image) = text(request, "iconImage") {
        content.insert("iconImage".to_string(), json!(png(image).ok_or("iconImage: Expected a small PNG")?));
    }
    let colors = request.get("colors").and_then(Value::as_array).cloned().unwrap_or_default();
    for (index, color) in colors.iter().enumerate() {
        if !color.as_str().is_some_and(is_hex_color) {
            return Err(format!("colors.{index}: Expected #RRGGBB"));
        }
    }
    content.insert(
        "colors".to_string(),
        Value::Array(colors.iter().filter_map(Value::as_str).map(|color| json!(color.to_uppercase())).collect()),
    );

    let items = request.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut depths: Vec<Option<usize>> = Vec::with_capacity(items.len());
    let mut stored = Vec::with_capacity(items.len());
    let mut tab_count = 0;
    for (index, item) in items.iter().enumerate() {
        let path = |field: &str| format!("items.{index}.{field}");
        let parent = item.get("parent").and_then(Value::as_f64).map(|parent| parent as usize);
        let depth = match parent {
            None => 0,
            Some(parent) if parent < index => match depths[parent] {
                Some(depth) if depth < MAX_FOLDER_DEPTH => depth + 1,
                Some(_) => return Err(format!("{}: Folders are nested too deep", path("parent"))),
                None => return Err(format!("{}: Expected an earlier folder", path("parent"))),
            },
            Some(_) => return Err(format!("{}: Expected an earlier folder", path("parent"))),
        };
        let mut entry = Map::new();
        let is_folder = text(item, "type") == Some("folder");
        entry.insert("type".to_string(), json!(if is_folder { "folder" } else { "tab" }));
        if let Some(title) = line(text(item, "title")) {
            entry.insert("title".to_string(), json!(title));
        }
        if let Some(parent) = parent {
            entry.insert("parent".to_string(), json!(parent));
        }
        if is_folder {
            if text(item, "url").is_some() || text(item, "favicon").is_some() {
                return Err(format!("{}: A folder has no address", path("url")));
            }
            if let Some(icon) = text(item, "icon") {
                entry.insert(
                    "icon".to_string(),
                    json!(icon_name(icon).ok_or(format!("{}: Invalid icon", path("icon")))?),
                );
            }
            depths.push(Some(depth));
        } else {
            let url = text(item, "url").ok_or(format!("{}: Required", path("url")))?;
            entry.insert(
                "url".to_string(),
                json!(web_url(url).ok_or(format!("{}: Expected a web address", path("url")))?),
            );
            if let Some(favicon) = text(item, "favicon") {
                entry.insert(
                    "favicon".to_string(),
                    json!(png(favicon).ok_or(format!("{}: Expected a small PNG", path("favicon")))?),
                );
            }
            if text(item, "icon").is_some() {
                return Err(format!("{}: A tab has no folder icon", path("icon")));
            }
            depths.push(None);
            tab_count += 1;
        }
        stored.push(Value::Object(entry));
    }
    if tab_count == 0 {
        return Err("items: Share at least one tab".to_string());
    }
    content.insert("items".to_string(), Value::Array(stored));
    Ok(Normalized {
        kind,
        source_id: text(request, "sourceID").unwrap_or_default().to_string(),
        title,
        excerpt: None,
        item_count: tab_count,
        content: Value::Object(content),
    })
}

fn quote(request: &Value) -> Result<Normalized, String> {
    let quote = paragraphs(text(request, "text").unwrap_or_default()).ok_or("text: Required")?;
    let url = web_url(text(request, "url").unwrap_or_default()).ok_or("url: Expected a web address")?;
    let mut content = Map::new();
    content.insert("text".to_string(), json!(quote));
    let title = line(text(request, "title"));
    if let Some(title) = &title {
        content.insert("title".to_string(), json!(title));
    }
    content.insert("url".to_string(), json!(url));
    if let Some(favicon) = text(request, "favicon") {
        content.insert("favicon".to_string(), json!(png(favicon).ok_or("favicon: Expected a small PNG")?));
    }
    // The same quote from the same page keeps its link.
    let digest = hex::encode(Sha256::digest(format!("{url}\n{quote}").as_bytes()));
    Ok(Normalized {
        kind: Kind::Quote,
        source_id: digest[..32].to_string(),
        title: title.unwrap_or_else(|| host(&url).unwrap_or_else(|| url.clone())),
        excerpt: Some(excerpt(&quote, 140)),
        item_count: 0,
        content: Value::Object(content),
    })
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// One line: whitespace runs and control characters become single spaces.
fn line(value: Option<&str>) -> Option<String> {
    let text = value?.split(|c: char| c.is_whitespace() || c.is_control()).filter(|word| !word.is_empty());
    let joined = text.collect::<Vec<_>>().join(" ");
    (!joined.is_empty()).then_some(joined)
}

/// Paragraphs kept, each on one line, with one blank line at most between them.
fn paragraphs(value: &str) -> Option<String> {
    let lines: Vec<String> = value.lines().map(|text| line(Some(text)).unwrap_or_default()).collect();
    let mut kept: Vec<String> = Vec::new();
    for text in lines {
        if text.is_empty() && kept.last().is_none_or(String::is_empty) {
            continue;
        }
        kept.push(text);
    }
    while kept.last().is_some_and(String::is_empty) {
        kept.pop();
    }
    (!kept.is_empty()).then(|| kept.join("\n"))
}

pub fn excerpt(text: &str, limit: usize) -> String {
    let single = line(Some(text)).unwrap_or_default();
    if single.chars().count() <= limit {
        return single;
    }
    let cut: String = single.chars().take(limit).collect();
    let cut = cut.rsplit_once(' ').map_or(cut.as_str(), |(head, _)| head).trim_end();
    format!("{cut}…")
}

/// An http or https address, as the URL parser writes it.
pub fn web_url(value: &str) -> Option<String> {
    let url = url::Url::parse(value.trim()).ok()?;
    (matches!(url.scheme(), "http" | "https") && url.host_str().is_some()).then(|| url.to_string())
}

pub fn host(value: &str) -> Option<String> {
    let url = url::Url::parse(value).ok()?;
    let host = url.host_str()?;
    Some(host.strip_prefix("www.").unwrap_or(host).to_string())
}

/// An emoji, or a symbol name such as `book.closed.fill`.
fn icon_name(value: &str) -> Option<String> {
    let value = value.trim();
    let symbol = value
        .split('.')
        .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit()));
    let emoji = !value.is_ascii() && value.chars().count() <= 16 && !value.chars().any(char::is_whitespace);
    (symbol || emoji).then(|| value.to_string())
}

fn is_hex_color(value: &str) -> bool {
    value.len() == 7 && value.starts_with('#') && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// A data URL of a PNG no larger than [`MAX_IMAGE_BYTES`].
fn png(value: &str) -> Option<String> {
    let encoded = value.strip_prefix(PNG_PREFIX)?;
    let bytes = STANDARD.decode(encoded).ok()?;
    (bytes.len() <= MAX_IMAGE_BYTES && bytes.starts_with(PNG_SIGNATURE)).then(|| value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::requests::SHARE_PUBLISH_REQUEST;

    fn png_url() -> String {
        format!("{PNG_PREFIX}{}", STANDARD.encode(b"\x89PNG\r\n\x1a\nrest"))
    }

    fn parse(value: Value) -> Result<Normalized, String> {
        let parsed = SHARE_PUBLISH_REQUEST.parse(&value).map_err(|issues| crate::schema::format_issues(&issues))?;
        normalize(&parsed)
    }

    fn space(items: Value) -> Value {
        json!({"kind": "space", "sourceID": "S1", "title": "  Reading\nlist ", "icon": "📚",
               "colors": ["#3139fb"], "items": items})
    }

    #[test]
    fn a_space_keeps_its_tree_and_counts_its_tabs() {
        let share = parse(space(json!([
            {"type": "folder", "title": "News", "icon": "newspaper"},
            {"type": "tab", "title": "Paper", "url": "https://example.com/a b", "parent": 0, "favicon": png_url()},
            {"type": "folder", "title": "Deep", "parent": 0},
            {"type": "tab", "url": "http://example.org", "parent": 2},
            {"type": "tab", "title": "Top", "url": "https://top.example"},
        ])))
        .unwrap();
        assert_eq!(share.kind, Kind::Space);
        assert_eq!(share.title, "Reading list");
        assert_eq!(share.item_count, 3);
        assert_eq!(share.source_id, "S1");
        assert_eq!(share.content["colors"], json!(["#3139FB"]));
        assert_eq!(share.content["items"][1]["url"], "https://example.com/a%20b");
        assert_eq!(share.content["items"][1]["parent"], 0);
        assert_eq!(share.content["items"][3]["url"], "http://example.org/");
        assert!(share.content["items"][3].get("title").is_none());
    }

    #[test]
    fn collections_reject_what_a_page_cannot_show() {
        let error = |items: Value| parse(space(items)).unwrap_err();
        assert!(error(json!([{"type": "tab", "url": "javascript:alert(1)"}])).contains("items.0.url"));
        assert!(error(json!([{"type": "tab", "url": "file:///etc/passwd"}])).contains("web address"));
        assert!(error(json!([{"type": "folder", "title": "Empty"}])).contains("at least one tab"));
        assert!(error(json!([{"type": "tab", "url": "https://a.example", "parent": 0}])).contains("earlier folder"));
        assert!(
            error(json!([{"type": "tab", "url": "https://a.example"}, {"type": "tab", "url": "https://b.example", "parent": 0}]))
                .contains("earlier folder")
        );
        assert!(
            error(json!([{"type": "tab", "url": "https://a.example", "favicon": "data:image/svg+xml,<svg/>"}]))
                .contains("PNG")
        );
        let big = format!("{PNG_PREFIX}{}", STANDARD.encode([PNG_SIGNATURE, &[0; MAX_IMAGE_BYTES - 7]].concat()));
        assert!(error(json!([{"type": "tab", "url": "https://a.example", "favicon": big}])).contains("PNG"));
        let mut deep = vec![json!({"type": "folder", "title": "0"})];
        for depth in 1..=MAX_FOLDER_DEPTH + 1 {
            deep.push(json!({"type": "folder", "title": depth.to_string(), "parent": depth - 1}));
        }
        deep.push(json!({"type": "tab", "url": "https://a.example"}));
        assert!(error(Value::Array(deep)).contains("too deep"));
        let mut bad_color = space(json!([{"type": "tab", "url": "https://a.example"}]));
        bad_color["colors"] = json!(["red1234"]);
        assert!(parse(bad_color).unwrap_err().contains("colors.0"));
        let mut bad_icon = space(json!([{"type": "tab", "url": "https://a.example"}]));
        bad_icon["icon"] = json!("<script>");
        assert!(parse(bad_icon).unwrap_err().contains("icon"));
    }

    #[test]
    fn a_quote_keeps_paragraphs_and_the_same_quote_keeps_its_source() {
        let request = json!({"kind": "quote", "text": "  First   line\r\n\r\n\r\nSecond\tline \n", "title": "A page",
                             "url": "https://www.example.com/post#:~:text=First%20line,Second%20line"});
        let share = parse(request.clone()).unwrap();
        assert_eq!(share.content["text"], "First line\n\nSecond line");
        assert_eq!(share.title, "A page");
        assert_eq!(share.excerpt.as_deref(), Some("First line Second line"));
        assert_eq!(share.source_id, parse(request).unwrap().source_id);
        let untitled = parse(json!({"kind": "quote", "text": "Words", "url": "https://www.example.com/"})).unwrap();
        assert_eq!(untitled.title, "example.com");
        assert!(parse(json!({"kind": "quote", "text": " \n ", "url": "https://example.com/"})).is_err());
        assert!(parse(json!({"kind": "quote", "text": "Words", "url": "data:text/html,hi"})).is_err());
    }

    #[test]
    fn excerpts_end_on_a_word() {
        assert_eq!(excerpt("one two three", 20), "one two three");
        assert_eq!(excerpt("one two three", 9), "one two…");
    }
}
