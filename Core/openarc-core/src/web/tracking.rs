//! Query parameters that only tell a site or an ad network where a click came from. Copy URL leaves them out,
//! so a shared link carries the page alone.

use super::components::UrlComponents;

const NAMES: &[&str] = &[
    "fbclid",
    "gclid",
    "gclsrc",
    "dclid",
    "gbraid",
    "wbraid",
    "msclkid",
    "yclid",
    "twclid",
    "ttclid",
    "li_fat_id",
    "igshid",
    "igsh",
    "mc_cid",
    "mc_eid",
    "_hsenc",
    "_hsmi",
    "mkt_tok",
    "vero_id",
    "vero_conv",
    "oly_anon_id",
    "oly_enc_id",
    "rb_clickid",
    "_openstat",
    "epik",
    "srsltid",
    "ref_src",
    "ref_url",
    "spm",
    "scm",
    "_ga",
    "_gl",
];

/// Share IDs that some sites add to every link copied from their share button.
const SHARE_NAMES_BY_SITE: &[(&str, &[&str])] = &[
    ("youtube.com", &["si", "pp", "feature"]),
    ("youtu.be", &["si", "feature"]),
    ("open.spotify.com", &["si"]),
    ("x.com", &["s", "t"]),
    ("twitter.com", &["s", "t"]),
    ("instagram.com", &["igsh", "img_index"]),
];

/// The address without tracking parameters; any other address as it was.
#[uniffi::export(name = "core_remove_tracking_parameters")]
pub fn remove_tracking_parameters(url: String) -> String {
    let Some(mut components) = UrlComponents::parse(&url) else {
        return url;
    };
    let Some(items) = components.percent_encoded_query_items().filter(|items| !items.is_empty()) else {
        return url;
    };
    let host = components.host().unwrap_or_default().to_lowercase();
    let kept: Vec<_> = items.iter().filter(|item| !is_tracking(&item.name, &host)).cloned().collect();
    if kept.len() == items.len() {
        return url;
    }
    components.set_percent_encoded_query_items((!kept.is_empty()).then_some(kept.as_slice()));
    components.string().unwrap_or(url)
}

fn is_tracking(name: &str, host: &str) -> bool {
    let name = name.to_lowercase();
    if name.starts_with("utm_") || NAMES.contains(&name.as_str()) {
        return true;
    }
    SHARE_NAMES_BY_SITE
        .iter()
        .any(|(site, names)| (host == *site || host.ends_with(&format!(".{site}"))) && names.contains(&name.as_str()))
}
