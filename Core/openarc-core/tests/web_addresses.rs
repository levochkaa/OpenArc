//! Every function of `web` against `fixtures/web-addresses.json`: the answers of the Swift code the core
//! replaced, recorded with Apple's Foundation, Network and the Public Suffix List. Android, Windows and Linux
//! get the same answers as the Mac and iOS.

use openarc_core::web::display::{url_display_string, url_full_display_string};
use openarc_core::web::domain::parse_host;
use openarc_core::web::internal_urls::{
    canonical_internal_url, chrome_engine_display_url, chrome_engine_load_url, chromium_internal_url, internal_url_host,
};
use openarc_core::web::navigation::{CoreNavigationKind, is_local_host, resolve_navigation};
use openarc_core::web::search_engine::{CoreSearchEngine, search_url};
use openarc_core::web::tracking::remove_tracking_parameters;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct Fixture {
    resolve: Vec<Resolve>,
    urls: Vec<Url>,
    search: Vec<BTreeMap<String, String>>,
    hosts: Vec<Host>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Resolve {
    input: String,
    kind: Option<String>,
    display_text: Option<String>,
    #[serde(rename = "resolvedURLString")]
    resolved_url: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Url {
    input: String,
    canonical_internal: Option<String>,
    chromium_internal: Option<String>,
    internal_host: Option<String>,
    chrome_engine_load: String,
    chrome_engine_display: String,
    /// `None` stands for the new tab title the app shows for a blank address.
    display: String,
    full_display: String,
    tracking_cleaned: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Host {
    host: String,
    is_local_host: bool,
    public_suffix: Option<String>,
    registrable_domain: Option<String>,
}

const NEW_TAB_TITLE: &str = "New Tab";

fn fixture() -> Fixture {
    serde_json::from_str(include_str!("fixtures/web-addresses.json")).expect("the fixture is valid JSON")
}

fn engine(name: &str) -> CoreSearchEngine {
    match name {
        "google" => CoreSearchEngine::Google,
        "microsoftBing" => CoreSearchEngine::MicrosoftBing,
        "yahoo" => CoreSearchEngine::Yahoo,
        "duckDuckGo" => CoreSearchEngine::DuckDuckGo,
        "ecosia" => CoreSearchEngine::Ecosia,
        "brave" => CoreSearchEngine::Brave,
        "qwant" => CoreSearchEngine::Qwant,
        "yandex" => CoreSearchEngine::Yandex,
        "baidu" => CoreSearchEngine::Baidu,
        other => panic!("unknown engine {other}"),
    }
}

/// Collects every mismatch, so one run shows them all.
#[derive(Default)]
struct Mismatches(Vec<String>);

impl Mismatches {
    fn check<T: PartialEq + std::fmt::Debug>(&mut self, what: &str, input: &str, actual: T, expected: T) {
        if actual != expected {
            self.0.push(format!("{what}({input:?}): got {actual:?}, expected {expected:?}"));
        }
    }

    fn assert_none(self) {
        assert!(self.0.is_empty(), "{} mismatches:\n{}", self.0.len(), self.0.join("\n"));
    }
}

#[test]
fn resolves_typed_text_as_before() {
    let mut mismatches = Mismatches::default();
    for case in fixture().resolve {
        let resolution = resolve_navigation(case.input.clone(), CoreSearchEngine::Google);
        let kind = resolution.as_ref().map(|resolution| match resolution.kind {
            CoreNavigationKind::Url => "url".to_owned(),
            CoreNavigationKind::Search => "search".to_owned(),
        });
        mismatches.check("kind", &case.input, kind, case.kind);
        mismatches.check(
            "displayText",
            &case.input,
            resolution.as_ref().map(|resolution| resolution.display_text.clone()),
            case.display_text,
        );
        mismatches.check(
            "resolvedURL",
            &case.input,
            resolution.map(|resolution| resolution.resolved_url),
            case.resolved_url,
        );
    }
    mismatches.assert_none();
}

#[test]
fn maps_and_shows_addresses_as_before() {
    let mut mismatches = Mismatches::default();
    for case in fixture().urls {
        let input = case.input.clone();
        mismatches.check("canonicalInternal", &input, canonical_internal_url(input.clone()), case.canonical_internal);
        mismatches.check("chromiumInternal", &input, chromium_internal_url(input.clone()), case.chromium_internal);
        mismatches.check("internalHost", &input, internal_url_host(input.clone()), case.internal_host);
        mismatches.check("chromeEngineLoad", &input, chrome_engine_load_url(input.clone()), case.chrome_engine_load);
        mismatches.check(
            "chromeEngineDisplay",
            &input,
            chrome_engine_display_url(input.clone()),
            case.chrome_engine_display,
        );
        let title = |shown: Option<String>| shown.unwrap_or_else(|| NEW_TAB_TITLE.to_owned());
        mismatches.check("display", &input, title(url_display_string(input.clone())), case.display);
        mismatches.check("fullDisplay", &input, title(url_full_display_string(input.clone())), case.full_display);
        mismatches.check("trackingCleaned", &input, remove_tracking_parameters(input.clone()), case.tracking_cleaned);
    }
    mismatches.assert_none();
}

#[test]
fn builds_search_pages_as_before() {
    let mut mismatches = Mismatches::default();
    for mut case in fixture().search {
        let query = case.remove("query").expect("every row has a query");
        for (name, expected) in case {
            mismatches.check(&name, &query, search_url(engine(&name), query.clone()), expected);
        }
    }
    mismatches.assert_none();
}

#[test]
fn reads_hosts_as_before() {
    let mut mismatches = Mismatches::default();
    for case in fixture().hosts {
        mismatches.check("isLocalHost", &case.host, is_local_host(case.host.clone()), case.is_local_host);
        let parsed = parse_host(case.host.clone());
        mismatches.check(
            "publicSuffix",
            &case.host,
            parsed.as_ref().map(|parsed| parsed.public_suffix.clone()),
            case.public_suffix,
        );
        mismatches.check(
            "registrableDomain",
            &case.host,
            parsed.and_then(|parsed| parsed.registrable_domain),
            case.registrable_domain,
        );
    }
    mismatches.assert_none();
}
