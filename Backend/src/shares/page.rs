//! The public pages of shared links, in the site's look: a blue field with
//! grain, cream rounded type, a paper card and one red action. The pages run
//! no script and load nothing from elsewhere: icons come inline as data URLs.

use super::content::{excerpt, host};
use super::{Kind, Share};
use serde_json::Value;
use std::fmt::Write;

const SITE: &str = "https://openarc.su";
const REPORT_ADDRESS: &str = "support@openarc.su";

/// What the page headers allow: inline styles and images, nothing fetched.
pub const CONTENT_SECURITY_POLICY: &str = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; \
     base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

/// The arch mark from the site's top bar.
const MARK: &str = r#"<svg class="mark" viewBox="0 0 40 36" aria-hidden="true"><path d="M20 3c4 0 6 3 7.5 7l7.5 18c1 2.5-.5 5-3 5-2 0-3-1.2-4-3.4L20 12l-8 17.6c-1 2.2-2 3.4-4 3.4-2.5 0-4-2.5-3-5l7.5-18C14 6 16 3 20 3Z"/></svg>"#;
const FOLDER_GLYPH: &str = r#"<svg class="glyph" viewBox="0 0 20 20" aria-hidden="true"><path d="M2.75 5.5c0-.97.78-1.75 1.75-1.75h3.3c.5 0 .97.21 1.3.58l1.07 1.17h5.33c.97 0 1.75.78 1.75 1.75v7.25c0 .97-.78 1.75-1.75 1.75h-11c-.97 0-1.75-.78-1.75-1.75Z"/></svg>"#;
const FAVICON: &str = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 36'%3E%3Crect width='40' height='36' rx='8' fill='%233139FB'/%3E%3Cpath fill='%23FFFADD' d='M20 7c3 0 4.5 2.2 5.6 5.2l5.6 13.4c.8 1.9-.4 3.7-2.2 3.7-1.5 0-2.3-.9-3-2.5L20 14l-6 13c-.7 1.6-1.5 2.5-3 2.5-1.9 0-3-1.9-2.2-3.7l5.6-13.4C15.5 9.2 17 7 20 7Z'/%3E%3C/svg%3E";

const STYLE: &str = r#"
:root {
  --blue: #3139fb;
  --cream: #fffadd;
  --paper: #fffcec;
  --ink: #1b1d3a;
  --muted: #5b5b6b;
  --red: #e5262b;
  --tile: #f3efd6;
  --display: ui-rounded, "SF Pro Rounded", "Nunito", -apple-system, BlinkMacSystemFont, sans-serif;
  --body: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --noise: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 .07 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>");
  color-scheme: light;
  font-family: var(--body);
  -webkit-font-smoothing: antialiased;
}
* { box-sizing: border-box; }
html { background: var(--blue); }
body {
  margin: 0;
  min-height: 100vh;
  min-height: 100dvh;
  display: flex;
  flex-direction: column;
  color: var(--cream);
  background: var(--blue) var(--noise);
}
a { color: inherit; cursor: pointer; }
a:focus-visible, summary:focus-visible {
  outline: 3px solid var(--cream);
  outline-offset: 3px;
  border-radius: 6px;
}
.card a:focus-visible, .card summary:focus-visible { outline-color: var(--blue); }
header { display: flex; justify-content: center; padding: 40px 16px 0; }
.home { display: block; padding: 6px; border-radius: 8px; color: var(--cream); }
.mark { display: block; width: 40px; height: 35px; fill: currentColor; }
main { width: 100%; max-width: 680px; margin: 0 auto; padding: 0 16px; flex: 1; }
.intro { margin-top: 40px; text-align: center; }
.badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 72px;
  height: 72px;
  border-radius: 14px;
  background: var(--tile);
  color: var(--blue);
  font: 800 34px/1 var(--display);
  overflow: hidden;
}
.badge img { width: 40px; height: 40px; }
h1 {
  margin: 20px 0 0;
  font: 800 clamp(34px, 7vw, 52px)/1.04 var(--display);
  letter-spacing: -0.02em;
  overflow-wrap: anywhere;
}
.meta { margin: 12px 0 0; font-size: 16px; line-height: 1.4; }
.actions { margin-top: 28px; display: flex; flex-direction: column; align-items: center; gap: 14px; }
.action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 220px;
  min-height: 52px;
  padding: 14px 24px;
  border-radius: 9px;
  background: var(--red);
  color: #fff;
  font: 700 16px/1.2 var(--body);
  text-decoration: none;
  transition: background-color 120ms ease;
}
.action:hover { background: #c81e23; }
.action:active { background: #ad1a1e; }
.hint { margin: 0; font-size: 14px; line-height: 1.45; max-width: 420px; }
.hint a { font-weight: 600; }
.card {
  margin: 40px 0 0;
  padding: 8px;
  border-radius: 14px;
  background: var(--paper);
  color: var(--ink);
}
.card ul { list-style: none; margin: 0; padding: 0; }
.card ul ul { padding-left: 22px; }
.row {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 48px;
  padding: 8px 10px;
  border-radius: 9px;
  text-decoration: none;
}
a.row:hover { background: var(--tile); }
.icon {
  flex: none;
  width: 20px;
  height: 20px;
  border-radius: 5px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: var(--tile);
  color: var(--muted);
  font: 700 12px/1 var(--body);
}
.icon img { width: 20px; height: 20px; border-radius: 5px; }
.glyph { flex: none; width: 20px; height: 20px; fill: none; stroke: var(--blue); stroke-width: 1.6; }
.label { min-width: 0; flex: 1; display: flex; flex-direction: column; }
.name, .where { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.name { font-size: 15px; line-height: 1.3; }
.where { font-size: 13px; line-height: 1.3; color: var(--muted); }
details > summary { list-style: none; cursor: pointer; font-weight: 650; }
details > summary::-webkit-details-marker { display: none; }
summary:hover { background: var(--tile); }
.chevron { flex: none; width: 10px; height: 10px; fill: none; stroke: var(--muted); stroke-width: 1.8; transition: transform 120ms ease; }
details[open] > summary .chevron { transform: rotate(90deg); }
.quote { margin: 40px 0 0; padding: 32px 28px 24px; border-radius: 14px; background: var(--paper); color: var(--ink); }
.quote-mark { display: block; height: 40px; color: var(--blue); font: 800 80px/1 var(--display); }
blockquote { margin: 8px 0 0; }
blockquote p { margin: 0 0 0.8em; font: 650 clamp(21px, 4.2vw, 28px)/1.4 var(--display); overflow-wrap: anywhere; }
blockquote.long p { font-size: clamp(18px, 3.2vw, 21px); line-height: 1.5; }
blockquote p:last-child { margin-bottom: 0; }
figcaption { margin-top: 24px; padding-top: 16px; border-top: 1px solid rgba(27, 29, 58, 0.14); display: flex; align-items: center; gap: 12px; }
.missing { margin-top: 64px; text-align: center; }
.missing p { margin: 16px auto 0; max-width: 440px; font-size: 17px; line-height: 1.45; }
footer { width: 100%; max-width: 680px; margin: 0 auto; padding: 48px 16px 32px; font-size: 13px; line-height: 1.5; text-align: center; }
footer nav { margin-top: 8px; display: flex; flex-wrap: wrap; justify-content: center; gap: 4px 18px; }
footer nav a { display: inline-block; padding: 6px 2px; }
@media (max-width: 520px) {
  header { padding-top: 28px; }
  .intro { margin-top: 28px; }
  .card { margin-top: 32px; padding: 4px; }
  .card ul ul { padding-left: 14px; }
  .quote { margin-top: 28px; padding: 24px 18px 18px; }
  .action { width: 100%; }
}
@media (prefers-reduced-motion: reduce) {
  .action, .chevron { transition: none; }
}
"#;

const CHEVRON: &str =
    r#"<svg class="chevron" viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 1.5 7 5l-3.5 3.5"/></svg>"#;

pub fn escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            _ => escaped.push(character),
        }
    }
    escaped
}

fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

struct Head<'a> {
    title: &'a str,
    description: &'a str,
    url: Option<&'a str>,
}

fn document(head: &Head, body: &str) -> String {
    let mut html = String::with_capacity(body.len() + STYLE.len() + 2048);
    html.push_str("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    html.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    html.push_str("<meta name=\"robots\" content=\"noindex\">\n");
    let _ = writeln!(html, "<title>{}</title>", escape(head.title));
    let _ = writeln!(html, "<meta name=\"description\" content=\"{}\">", escape(head.description));
    let _ = writeln!(html, "<meta property=\"og:site_name\" content=\"OpenArc\">");
    let _ = writeln!(html, "<meta property=\"og:type\" content=\"website\">");
    let _ = writeln!(html, "<meta property=\"og:title\" content=\"{}\">", escape(head.title));
    let _ = writeln!(html, "<meta property=\"og:description\" content=\"{}\">", escape(head.description));
    if let Some(url) = head.url {
        let _ = writeln!(html, "<meta property=\"og:url\" content=\"{}\">", escape(url));
        let _ = writeln!(html, "<link rel=\"canonical\" href=\"{}\">", escape(url));
    }
    let _ = writeln!(html, "<meta name=\"twitter:card\" content=\"summary\">");
    let _ = writeln!(html, "<meta name=\"theme-color\" content=\"#3139fb\">");
    let _ = writeln!(html, "<link rel=\"icon\" href=\"{FAVICON}\">");
    let _ = writeln!(html, "<style>{STYLE}</style>\n</head>\n<body>");
    let _ = writeln!(html, "<header><a class=\"home\" href=\"{SITE}\" aria-label=\"OpenArc home\">{MARK}</a></header>");
    html.push_str(body);
    html.push_str("</body>\n</html>\n");
    html
}

fn footer(report_url: Option<&str>) -> String {
    let about = if report_url.is_some() {
        "Shared from OpenArc, a free, open-source browser for Mac."
    } else {
        "OpenArc is a free, open-source browser for Mac."
    };
    let mut footer = format!("<footer>\n<p>{about}</p>\n<nav aria-label=\"OpenArc\">");
    let _ = write!(footer, "<a href=\"{SITE}\">Download OpenArc for Mac</a><a href=\"{SITE}/privacy/\">Privacy</a>");
    if let Some(url) = report_url {
        let subject = url::form_urlencoded::byte_serialize(format!("Report {url}").as_bytes()).collect::<String>();
        let _ = write!(
            footer,
            "<a href=\"mailto:{REPORT_ADDRESS}?subject={}\">Report this link</a>",
            subject.replace('+', "%20")
        );
    }
    footer.push_str("</nav>\n</footer>\n");
    footer
}

fn str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// A favicon, or the site's first letter on a tile.
fn site_icon(favicon: Option<&str>, url: &str) -> String {
    match favicon {
        Some(data) => {
            format!("<span class=\"icon\"><img src=\"{}\" width=\"20\" height=\"20\" alt=\"\"></span>", escape(data))
        }
        None => {
            let letter = host(url).and_then(|host| host.chars().next()).map(|c| c.to_uppercase().to_string());
            format!("<span class=\"icon\" aria-hidden=\"true\">{}</span>", escape(&letter.unwrap_or_default()))
        }
    }
}

/// The page of a shared Space or folder: its title and tabs, and the action
/// that adds them to OpenArc.
pub fn collection(share: &Share, url: &str) -> String {
    let content = &share.content;
    let title = str_field(content, "title").unwrap_or("Shared tabs");
    let items: Vec<&Value> =
        content.get("items").and_then(Value::as_array).map(|items| items.iter().collect()).unwrap_or_default();
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); items.len()];
    let mut roots = Vec::new();
    for (index, item) in items.iter().enumerate() {
        match item.get("parent").and_then(Value::as_u64).map(|parent| parent as usize) {
            Some(parent) if parent < index => children[parent].push(index),
            _ => roots.push(index),
        }
    }
    let tabs = items.iter().filter(|item| str_field(item, "type") == Some("tab")).count();
    let folders = items.len() - tabs;
    let noun = if share.kind == Kind::Folder { "Folder" } else { "Space" };
    let counts = if folders == 0 {
        plural(tabs, "tab", "tabs")
    } else {
        format!("{} in {}", plural(tabs, "tab", "tabs"), plural(folders, "folder", "folders"))
    };
    let shared_on = share.updated_at.format("%b %-d, %Y");
    let description = format!("A {} with {}, shared from OpenArc.", noun.to_lowercase(), plural(tabs, "tab", "tabs"));

    let mut body = String::from("<main>\n<section class=\"intro\" aria-labelledby=\"title\">\n");
    body.push_str(&badge(content, title));
    let _ = writeln!(body, "<h1 id=\"title\">{}</h1>", escape(title));
    let _ = writeln!(body, "<p class=\"meta\">{noun} · {counts} · Shared {shared_on}</p>");
    let destination = if share.kind == Kind::Folder { "a folder in your current Space" } else { "a new Space" };
    let _ = writeln!(
        body,
        "<div class=\"actions\"><a class=\"action\" href=\"openarc://share/{id}\">Add to OpenArc</a>\
         <p class=\"hint\">Adds these tabs to OpenArc as {destination}. No OpenArc yet? \
         <a href=\"{SITE}\">Download it for Mac</a>.</p></div>",
        id = escape(&share.id),
    );
    body.push_str("</section>\n<section class=\"card\" aria-label=\"Tabs\">\n");
    render_list(&mut body, &items, &children, &roots);
    body.push_str("</section>\n</main>\n");
    body.push_str(&footer(Some(url)));
    document(&Head { title: &format!("{title} · OpenArc"), description: &description, url: Some(url) }, &body)
}

fn badge(content: &Value, title: &str) -> String {
    let color =
        content.get("colors").and_then(Value::as_array).and_then(|colors| colors.first()).and_then(Value::as_str);
    // The Space's own color; its letters stay readable on it.
    let style = color
        .map(|color| {
            let letters = if luminance(color).unwrap_or(1.0) < 0.4 { "#fffadd" } else { "#1b1d3a" };
            format!(" style=\"background:{};color:{letters}\"", escape(color))
        })
        .unwrap_or_default();
    let inner = if let Some(image) = str_field(content, "iconImage") {
        format!("<img src=\"{}\" width=\"40\" height=\"40\" alt=\"\">", escape(image))
    } else if let Some(emoji) = str_field(content, "icon").filter(|icon| !icon.is_ascii()) {
        escape(emoji)
    } else {
        escape(&title.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default())
    };
    format!("<span class=\"badge\" aria-hidden=\"true\"{style}>{inner}</span>\n")
}

/// Relative luminance of `#RRGGBB`.
fn luminance(color: &str) -> Option<f64> {
    let channel = |range: std::ops::Range<usize>| -> Option<f64> {
        let value = f64::from(u8::from_str_radix(color.get(range)?, 16).ok()?) / 255.0;
        Some(if value <= 0.039_28 { value / 12.92 } else { ((value + 0.055) / 1.055).powf(2.4) })
    };
    Some(0.2126 * channel(1..3)? + 0.7152 * channel(3..5)? + 0.0722 * channel(5..7)?)
}

fn render_list(body: &mut String, items: &[&Value], children: &[Vec<usize>], indices: &[usize]) {
    body.push_str("<ul>\n");
    for &index in indices {
        let item = items[index];
        body.push_str("<li>");
        if str_field(item, "type") == Some("folder") {
            let title = str_field(item, "title").unwrap_or("Untitled folder");
            let count = plural(count_tabs(items, children, index), "tab", "tabs");
            let _ = write!(
                body,
                "<details open><summary class=\"row\">{CHEVRON}{FOLDER_GLYPH}<span class=\"label\"><span class=\"name\">{}</span>\
                 <span class=\"where\">{count}</span></span></summary>",
                escape(title),
            );
            render_list(body, items, children, &children[index]);
            body.push_str("</details>");
        } else {
            let url = str_field(item, "url").unwrap_or_default();
            let site = host(url).unwrap_or_default();
            let title = str_field(item, "title").unwrap_or(&site);
            let _ = write!(
                body,
                "<a class=\"row\" href=\"{}\" rel=\"nofollow noopener ugc\">{}<span class=\"label\">\
                 <span class=\"name\">{}</span><span class=\"where\">{}</span></span></a>",
                escape(url),
                site_icon(str_field(item, "favicon"), url),
                escape(title),
                escape(&site),
            );
        }
        body.push_str("</li>\n");
    }
    body.push_str("</ul>\n");
}

fn count_tabs(items: &[&Value], children: &[Vec<usize>], index: usize) -> usize {
    children[index]
        .iter()
        .map(
            |&child| {
                if str_field(items[child], "type") == Some("folder") { count_tabs(items, children, child) } else { 1 }
            },
        )
        .sum()
}

/// The page of a shared quote: the words, where they come from, and the
/// action that opens the page at them.
pub fn quote(share: &Share, url: &str) -> String {
    let content = &share.content;
    let text = str_field(content, "text").unwrap_or_default();
    let source = str_field(content, "url").unwrap_or(SITE);
    let site = host(source).unwrap_or_default();
    let page_title = str_field(content, "title").unwrap_or(&site);
    let long = text.chars().count() > 280;

    let mut body =
        String::from("<main>\n<figure class=\"quote\">\n<span class=\"quote-mark\" aria-hidden=\"true\">“</span>\n");
    let _ = writeln!(body, "<blockquote{} cite=\"{}\">", if long { " class=\"long\"" } else { "" }, escape(source));
    for paragraph in text.split('\n').filter(|paragraph| !paragraph.is_empty()) {
        let _ = writeln!(body, "<p>{}</p>", escape(paragraph));
    }
    body.push_str("</blockquote>\n<figcaption>");
    body.push_str(&site_icon(str_field(content, "favicon"), source));
    let _ = writeln!(
        body,
        "<span class=\"label\"><span class=\"name\">{}</span><span class=\"where\">{}</span></span></figcaption>\n</figure>",
        escape(page_title),
        escape(&site),
    );
    let _ = writeln!(
        body,
        "<div class=\"actions\"><a class=\"action\" href=\"{}\" rel=\"nofollow noopener ugc\">Read it on {}</a></div>\n</main>",
        escape(source),
        escape(&site),
    );
    body.push_str(&footer(Some(url)));
    let title = format!("“{}”", excerpt(text, 90));
    let description = format!("From {page_title} ({site}). Shared from OpenArc.");
    document(&Head { title: &title, description: &description, url: Some(url) }, &body)
}

/// The page of a link that was removed or never existed.
pub fn missing() -> String {
    let body = format!(
        "<main>\n<section class=\"missing\" aria-labelledby=\"title\">\n<h1 id=\"title\">This link was removed</h1>\n\
         <p>Whoever shared it took it down, or the address has a typo.</p>\n\
         <div class=\"actions\"><a class=\"action\" href=\"{SITE}\">Go to openarc.su</a></div>\n</section>\n</main>\n{}",
        footer(None),
    );
    document(&Head { title: "Link removed · OpenArc", description: "This shared link was removed.", url: None }, &body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn share(kind: Kind, content: Value) -> Share {
        let date = chrono::Utc.with_ymd_and_hms(2026, 11, 19, 12, 0, 0).unwrap();
        Share { id: "AbCdEfGh12".to_string(), kind, content, created_at: date, updated_at: date }
    }

    #[test]
    fn a_space_page_lists_its_tree_escaped_with_one_action() {
        let page = collection(
            &share(
                Kind::Space,
                json!({
                    "title": "Work <b>", "icon": "🧪", "colors": ["#1B1D3A"],
                    "items": [
                        {"type": "folder", "title": "Docs & \"specs\""},
                        {"type": "tab", "title": "<script>alert(1)</script>", "url": "https://www.example.com/a?b=1&c='x'", "parent": 0},
                        {"type": "tab", "url": "https://other.example/"},
                    ],
                }),
            ),
            "https://openarc.su/s/AbCdEfGh12",
        );
        assert!(page.contains("<h1 id=\"title\">Work &lt;b&gt;</h1>"));
        assert!(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
        assert!(!page.contains("<script>"));
        assert!(page.contains("href=\"https://www.example.com/a?b=1&amp;c=&#39;x&#39;\""));
        assert!(page.contains("Docs &amp; &quot;specs&quot;"));
        assert!(page.contains("Space · 2 tabs in 1 folder · Shared Nov 19, 2026"));
        assert!(page.contains("href=\"openarc://share/AbCdEfGh12\""));
        assert!(page.contains("<meta property=\"og:title\" content=\"Work &lt;b&gt; · OpenArc\">"));
        assert!(page.contains("style=\"background:#1B1D3A;color:#fffadd\""));
        assert!(page.contains(">🧪</span>"));
        // An untitled tab shows its site.
        assert!(page.contains("<span class=\"name\">other.example</span>"));
        assert_eq!(page.matches("class=\"action\"").count(), 1);
        assert!(!page.contains('—'));
    }

    #[test]
    fn a_folder_page_says_where_its_tabs_go() {
        let page = collection(
            &share(Kind::Folder, json!({"title": "Recipes", "items": [{"type": "tab", "url": "https://a.example/"}]})),
            "https://openarc.su/s/AbCdEfGh12",
        );
        assert!(page.contains("Folder · 1 tab · Shared"));
        assert!(page.contains("as a folder in your current Space"));
        assert!(page.contains("A folder with 1 tab, shared from OpenArc."));
    }

    #[test]
    fn a_quote_page_shows_paragraphs_and_links_to_the_highlight() {
        let page = quote(
            &share(
                Kind::Quote,
                json!({"text": "First <line>\n\nSecond", "title": "Post",
                                        "url": "https://example.com/post#:~:text=First"}),
            ),
            "https://openarc.su/q/AbCdEfGh12",
        );
        assert!(page.contains("<p>First &lt;line&gt;</p>\n<p>Second</p>"));
        assert!(page.contains(
            "href=\"https://example.com/post#:~:text=First\" rel=\"nofollow noopener ugc\">Read it on example.com"
        ));
        assert!(page.contains("<title>“First &lt;line&gt; Second”</title>"));
        assert!(page.contains("Report%20https%3A%2F%2Fopenarc.su%2Fq%2FAbCdEfGh12"));
    }

    #[test]
    fn the_missing_page_has_no_report_link() {
        let page = missing();
        assert!(page.contains("This link was removed"));
        assert!(!page.contains("Report this link"));
        assert!(!page.contains("Shared from"));
    }
}
