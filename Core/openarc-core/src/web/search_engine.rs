//! Search engines the address bar can send a query to.

use super::components::UrlComponents;

/// The engine choice in Settings ▸ Search.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSearchEngine {
    Google,
    MicrosoftBing,
    Yahoo,
    DuckDuckGo,
    Ecosia,
    Brave,
    Qwant,
    Yandex,
    Baidu,
}

impl CoreSearchEngine {
    /// Host, path and query parameter of the engine's results page.
    fn results_page(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Google => ("www.google.com", "/search", "q"),
            Self::MicrosoftBing => ("www.bing.com", "/search", "q"),
            Self::Yahoo => ("search.yahoo.com", "/search", "p"),
            Self::DuckDuckGo => ("duckduckgo.com", "/", "q"),
            Self::Ecosia => ("www.ecosia.org", "/search", "q"),
            Self::Brave => ("search.brave.com", "/search", "q"),
            Self::Qwant => ("www.qwant.com", "/", "q"),
            Self::Yandex => ("yandex.com", "/search/", "text"),
            Self::Baidu => ("www.baidu.com", "/s", "wd"),
        }
    }
}

/// The engine's results page for `query`.
#[uniffi::export(name = "core_search_url")]
pub fn search_url(engine: CoreSearchEngine, query: String) -> String {
    let (host, path, parameter) = engine.results_page();
    let mut components = UrlComponents::new();
    components.set_scheme("https");
    components.set_host(Some(host));
    components.set_path(path);
    components.set_query_items(&[(parameter, Some(&query))]);
    components.string().expect("search pages are valid addresses")
}
