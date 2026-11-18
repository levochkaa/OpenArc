//! Environment configuration. `.env` is read first without replacing
//! variables that are already set.

use regex::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub database_url: String,
    /// 0 binds an ephemeral port, which test harnesses read from the log line.
    pub port: u16,
    pub host: String,
    /// The exact Apple client IDs accepted as identity token audiences.
    pub apple_client_ids: Vec<String>,
    pub jwt_secret: String,
    pub jwt_issuer: String,
    pub jwt_audience: String,
    pub cors_origin: String,
    pub github_release_repository: Option<String>,
    pub github_release_token: String,
    pub public_base_url: Option<String>,
    /// Where the pages of shared links live, without a trailing slash.
    pub share_base_url: String,
    pub update_appcast_asset: String,
    pub sign_in: SignInConfig,
}

/// Sign-in methods besides native Sign in with Apple. A method is offered
/// only when it is configured.
#[derive(Clone, Debug, PartialEq)]
pub struct SignInConfig {
    /// The Services ID of Sign in with Apple on the web.
    pub apple_services_id: Option<String>,
    pub google: Option<OAuthClient>,
    pub github: Option<OAuthClient>,
    /// The mail server that sends sign-in codes; any provider's SMTP works.
    pub smtp: Option<SmtpConfig>,
    pub email_from: String,
    pub endpoints: ProviderEndpoints,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub security: SmtpSecurity,
    pub credentials: Option<(String, String)>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SmtpSecurity {
    /// TLS from the first byte, usually port 465.
    Tls,
    /// A plain connection upgraded with STARTTLS, usually port 587.
    StartTls,
    /// No encryption, only to a mail server on this machine.
    None,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OAuthClient {
    pub id: String,
    pub secret: String,
}

/// The providers' endpoints. Only tests override them.
#[derive(Clone, Debug, PartialEq)]
pub struct ProviderEndpoints {
    pub apple_keys: String,
    pub apple_authorize: String,
    pub google_authorize: String,
    pub google_token: String,
    pub github_authorize: String,
    pub github_token: String,
    pub github_api: String,
}

static APPLE_CLIENT_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$").expect("valid regex"));

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Self::parse(&std::env::vars().collect())
    }

    pub fn parse(environment: &HashMap<String, String>) -> Result<Self, String> {
        let mut issues = Vec::new();
        let value = |key: &str| environment.get(key).cloned();

        let database_url = value("DATABASE_URL").unwrap_or_default();
        if database_url.is_empty() {
            issues.push("DATABASE_URL: required".to_string());
        }

        let port = match value("PORT") {
            None => 8080,
            Some(text) => match js_number(&text) {
                Some(number) if number.fract() == 0.0 && (0.0..=65535.0).contains(&number) => number as u16,
                _ => {
                    issues.push("PORT: expected an integer port".to_string());
                    0
                }
            },
        };
        let host = value("HOST").unwrap_or_else(|| "0.0.0.0".to_string());

        let single_id = value("APPLE_CLIENT_ID").map(|text| apple_client_id(&text));
        if let Some(Err(issue)) = &single_id {
            issues.push(format!("APPLE_CLIENT_ID: {issue}"));
        }
        let apple_client_ids =
            value("APPLE_CLIENT_IDS").map(|text| text.split(',').map(apple_client_id).collect::<Result<Vec<_>, _>>());
        if let Some(Err(issue)) = &apple_client_ids {
            issues.push(format!("APPLE_CLIENT_IDS: {issue}"));
        }
        let apple_client_ids = match (apple_client_ids, single_id) {
            (Some(Ok(ids)), _) => dedupe(ids),
            (None, Some(Ok(id))) => vec![id],
            (None, None) => {
                issues.push("APPLE_CLIENT_ID: Configure APPLE_CLIENT_IDS or APPLE_CLIENT_ID".to_string());
                Vec::new()
            }
            _ => Vec::new(),
        };

        let jwt_secret = value("JWT_SECRET").unwrap_or_default();
        if jwt_secret.encode_utf16().count() < 32 {
            issues.push("JWT_SECRET: must contain at least 32 characters".to_string());
        }

        let public_base_url = value("OPENARC_PUBLIC_BASE_URL");
        if let Some(url) = &public_base_url
            && url::Url::parse(url).is_err()
        {
            issues.push("OPENARC_PUBLIC_BASE_URL: Invalid URL".to_string());
        }
        let share_base_url = value("OPENARC_SHARE_BASE_URL").unwrap_or_else(|| "https://openarc.su".to_string());
        if !url::Url::parse(&share_base_url).is_ok_and(|url| matches!(url.scheme(), "http" | "https")) {
            issues.push("OPENARC_SHARE_BASE_URL: Invalid URL".to_string());
        }
        let share_base_url = share_base_url.trim_end_matches('/').to_string();
        let update_appcast_asset = value("OPENARC_UPDATE_APPCAST_ASSET").unwrap_or_else(|| "appcast.xml".to_string());
        if update_appcast_asset.is_empty() {
            issues.push("OPENARC_UPDATE_APPCAST_ASSET: must not be empty".to_string());
        }

        let sign_in = sign_in_config(&value, public_base_url.is_some(), &mut issues);

        if !issues.is_empty() {
            return Err(issues.join("; "));
        }
        Ok(Self {
            database_url,
            port,
            host,
            apple_client_ids,
            jwt_secret,
            jwt_issuer: value("JWT_ISSUER").unwrap_or_else(|| "openarc-sync".to_string()),
            jwt_audience: value("JWT_AUDIENCE").unwrap_or_else(|| "openarc-clients".to_string()),
            cors_origin: value("CORS_ORIGIN").unwrap_or_default(),
            github_release_repository: value("GITHUB_RELEASE_REPOSITORY"),
            github_release_token: value("GITHUB_RELEASE_TOKEN").unwrap_or_default(),
            public_base_url,
            share_base_url,
            update_appcast_asset,
            sign_in,
        })
    }
}

fn sign_in_config(
    value: &dyn Fn(&str) -> Option<String>,
    has_public_base_url: bool,
    issues: &mut Vec<String>,
) -> SignInConfig {
    let present = |key: &str| value(key).filter(|text| !text.trim().is_empty());
    let mut client = |name: &str| {
        let id = present(&format!("OPENARC_{name}_CLIENT_ID"));
        let secret = present(&format!("OPENARC_{name}_CLIENT_SECRET"));
        match (id, secret) {
            (Some(id), Some(secret)) => Some(OAuthClient { id, secret }),
            (None, None) => None,
            _ => {
                issues.push(format!("OPENARC_{name}_CLIENT_ID and OPENARC_{name}_CLIENT_SECRET: set both or neither"));
                None
            }
        }
    };
    let google = client("GOOGLE");
    let github = client("GITHUB");
    let apple_services_id = present("OPENARC_APPLE_SERVICES_ID");
    if (apple_services_id.is_some() || google.is_some() || github.is_some()) && !has_public_base_url {
        issues.push("OPENARC_PUBLIC_BASE_URL: required for web sign-in, whose redirects return to it".to_string());
    }
    let endpoint = |key: &str, default: &str| present(key).unwrap_or_else(|| default.to_string());
    SignInConfig {
        apple_services_id,
        google,
        github,
        smtp: smtp_config(&present, issues),
        email_from: endpoint("OPENARC_EMAIL_FROM", "OpenArc <support@openarc.su>"),
        endpoints: ProviderEndpoints {
            apple_keys: endpoint("OPENARC_APPLE_KEYS_URL", crate::auth::APPLE_KEYS_URL),
            apple_authorize: endpoint("OPENARC_APPLE_AUTHORIZE_URL", "https://appleid.apple.com/auth/authorize"),
            google_authorize: endpoint("OPENARC_GOOGLE_AUTHORIZE_URL", "https://accounts.google.com/o/oauth2/v2/auth"),
            google_token: endpoint("OPENARC_GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token"),
            github_authorize: endpoint("OPENARC_GITHUB_AUTHORIZE_URL", "https://github.com/login/oauth/authorize"),
            github_token: endpoint("OPENARC_GITHUB_TOKEN_URL", "https://github.com/login/oauth/access_token"),
            github_api: endpoint("OPENARC_GITHUB_API_URL", "https://api.github.com"),
        },
    }
}

fn smtp_config(present: &dyn Fn(&str) -> Option<String>, issues: &mut Vec<String>) -> Option<SmtpConfig> {
    let host = present("OPENARC_SMTP_HOST")?;
    let port = present("OPENARC_SMTP_PORT").map(|text| text.trim().parse::<u16>());
    if let Some(Err(_)) = &port {
        issues.push("OPENARC_SMTP_PORT: expected a port number".to_string());
    }
    let port = port.and_then(Result::ok);
    let security = match present("OPENARC_SMTP_SECURITY").as_deref().map(str::trim) {
        Some("tls") => SmtpSecurity::Tls,
        Some("starttls") => SmtpSecurity::StartTls,
        Some("none") => SmtpSecurity::None,
        Some(_) => {
            issues.push("OPENARC_SMTP_SECURITY: expected tls, starttls or none".to_string());
            SmtpSecurity::StartTls
        }
        None if port == Some(465) => SmtpSecurity::Tls,
        None => SmtpSecurity::StartTls,
    };
    if security == SmtpSecurity::None && !matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1") {
        issues.push("OPENARC_SMTP_SECURITY: none is only allowed for a mail server on this machine".to_string());
    }
    let credentials = match (present("OPENARC_SMTP_USERNAME"), present("OPENARC_SMTP_PASSWORD")) {
        (Some(username), Some(password)) => Some((username, password)),
        (None, None) => None,
        _ => {
            issues.push("OPENARC_SMTP_USERNAME and OPENARC_SMTP_PASSWORD: set both or neither".to_string());
            None
        }
    };
    let port = port.unwrap_or(match security {
        SmtpSecurity::Tls => 465,
        SmtpSecurity::StartTls => 587,
        SmtpSecurity::None => 25,
    });
    Some(SmtpConfig { host, port, security, credentials })
}

/// A trimmed identifier made of dot-separated segments: no empty segments,
/// wildcards, spaces, schemes or other separators.
fn apple_client_id(text: &str) -> Result<String, String> {
    let trimmed = text.trim();
    if APPLE_CLIENT_ID.is_match(trimmed) {
        Ok(trimmed.to_string())
    } else {
        Err("Apple client IDs must contain only identifier segments, without empty segments or wildcards".to_string())
    }
}

fn dedupe(ids: Vec<String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for id in ids {
        if !result.contains(&id) {
            result.push(id);
        }
    }
    result
}

/// JavaScript's `Number(text)` for decimal, hexadecimal, octal and binary
/// literals; None where JavaScript yields NaN.
pub fn js_number(text: &str) -> Option<f64> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Some(0.0);
    }
    for (prefix, radix) in [("0x", 16), ("0X", 16), ("0o", 8), ("0O", 8), ("0b", 2), ("0B", 2)] {
        if let Some(digits) = trimmed.strip_prefix(prefix) {
            return u64::from_str_radix(digits, radix).ok().map(|value| value as f64);
        }
    }
    match trimmed {
        "Infinity" | "+Infinity" => return Some(f64::INFINITY),
        "-Infinity" => return Some(f64::NEG_INFINITY),
        _ => {}
    }
    let valid =
        trimmed.chars().all(|character| character.is_ascii_digit() || matches!(character, '.' | 'e' | 'E' | '+' | '-'));
    if !valid || trimmed.contains("inf") {
        return None;
    }
    trimmed.parse::<f64>().ok()
}

/// Reads `.env` from the working directory as Node's `dotenv` does: no
/// variable expansion, `\n` and `\r` escapes only in double quotes, and
/// variables already set win.
pub fn load_dotenv() {
    let Ok(text) = std::fs::read_to_string(".env") else { return };
    for (key, value) in parse_dotenv(&text) {
        if std::env::var_os(&key).is_none() {
            // SAFETY: called once at startup, before any other thread exists.
            unsafe { std::env::set_var(key, value) };
        }
    }
}

pub fn parse_dotenv(text: &str) -> Vec<(String, String)> {
    static LINE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?m)^\s*(?:export\s+)?([A-Za-z0-9_.-]+)(?:\s*=\s*?|:\s+?)(\s*'(?:\\'|[^'])*'|\s*"(?:\\"|[^"])*"|\s*`(?:\\`|[^`])*`|[^#\r\n]+)?\s*(?:#.*)?$"#,
        )
        .expect("valid regex")
    });
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    LINE.captures_iter(&text)
        .map(|captures| {
            let key = captures[1].to_string();
            let value = captures.get(2).map_or("", |value| value.as_str()).trim();
            let quote = value.chars().next();
            let unquoted = match quote {
                Some(quote @ ('\'' | '"' | '`')) if value.len() >= 2 && value.ends_with(quote) => {
                    &value[1..value.len() - 1]
                }
                _ => value,
            };
            let value = if quote == Some('"') {
                unquoted.replace("\\n", "\n").replace("\\r", "\r")
            } else {
                unquoted.to_string()
            };
            (key, value)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DESKTOP: &str = "com.openarc.auth-test-desktop";
    const MOBILE: &str = "com.openarc.auth-test-mobile";

    fn required() -> HashMap<String, String> {
        HashMap::from([
            ("DATABASE_URL".to_string(), "postgres://test:test@127.0.0.1:5432/openarc_auth_test".to_string()),
            ("JWT_SECRET".to_string(), "local-auth-test-secret-at-least-thirty-two-bytes".to_string()),
        ])
    }

    fn with(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        let mut environment = required();
        for (key, value) in pairs {
            environment.insert((*key).to_string(), (*value).to_string());
        }
        environment
    }

    /// A valid environment with these SMTP settings.
    fn smtp(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        let mut environment = with(pairs);
        environment.insert("APPLE_CLIENT_ID".to_string(), DESKTOP.to_string());
        environment
    }

    #[test]
    fn smtp_picks_starttls_or_tls_from_the_port_and_takes_credentials_in_pairs() {
        let host = ("OPENARC_SMTP_HOST", "smtp.example.test");
        assert_eq!(
            Config::parse(&smtp(&[host])).unwrap().sign_in.smtp,
            Some(SmtpConfig {
                host: "smtp.example.test".to_string(),
                port: 587,
                security: SmtpSecurity::StartTls,
                credentials: None,
            })
        );
        let tls = Config::parse(&smtp(&[
            host,
            ("OPENARC_SMTP_PORT", "465"),
            ("OPENARC_SMTP_USERNAME", "user"),
            ("OPENARC_SMTP_PASSWORD", "secret"),
        ]))
        .unwrap()
        .sign_in
        .smtp
        .unwrap();
        assert_eq!((tls.port, tls.security), (465, SmtpSecurity::Tls));
        assert_eq!(tls.credentials, Some(("user".to_string(), "secret".to_string())));
        assert_eq!(Config::parse(&smtp(&[])).unwrap().sign_in.smtp, None);
    }

    #[test]
    fn smtp_refuses_plain_text_to_other_machines_half_credentials_and_unknown_security() {
        let host = ("OPENARC_SMTP_HOST", "smtp.example.test");
        assert!(Config::parse(&smtp(&[host, ("OPENARC_SMTP_SECURITY", "none")])).is_err());
        assert!(Config::parse(&smtp(&[("OPENARC_SMTP_HOST", "127.0.0.1"), ("OPENARC_SMTP_SECURITY", "none")])).is_ok());
        assert!(Config::parse(&smtp(&[host, ("OPENARC_SMTP_USERNAME", "user")])).is_err());
        assert!(Config::parse(&smtp(&[host, ("OPENARC_SMTP_SECURITY", "ssl")])).is_err());
        assert!(Config::parse(&smtp(&[host, ("OPENARC_SMTP_PORT", "smtp")])).is_err());
    }

    #[test]
    fn retains_the_single_configured_desktop_audience_as_the_default() {
        let config = Config::parse(&with(&[("APPLE_CLIENT_ID", &format!(" {DESKTOP} "))])).unwrap();
        assert_eq!(config.apple_client_ids, vec![DESKTOP]);
        assert_eq!(config.port, 8080);
        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.jwt_issuer, "openarc-sync");
        assert_eq!(config.jwt_audience, "openarc-clients");
        assert_eq!(config.update_appcast_asset, "appcast.xml");
    }

    #[test]
    fn trims_and_deduplicates_an_explicit_list_without_adding_the_fallback() {
        let list = format!(" {DESKTOP}, {MOBILE}, {DESKTOP} ");
        let config =
            Config::parse(&with(&[("APPLE_CLIENT_ID", "com.openarc.unlisted"), ("APPLE_CLIENT_IDS", &list)])).unwrap();
        assert_eq!(config.apple_client_ids, vec![DESKTOP, MOBILE]);
        assert_eq!(Config::parse(&with(&[("APPLE_CLIENT_IDS", MOBILE)])).unwrap().apple_client_ids, vec![MOBILE]);
    }

    #[test]
    fn fails_closed_for_absent_empty_wildcard_and_malformed_audiences() {
        assert!(Config::parse(&required()).is_err());
        let invalid_lists = [
            String::new(),
            " ".to_string(),
            format!(",{MOBILE}"),
            format!("{DESKTOP},"),
            format!("{DESKTOP}, ,{MOBILE}"),
            "*".to_string(),
            "com.openarc.*".to_string(),
            "https://example.test".to_string(),
            "com..openarc".to_string(),
            "com.openarc mobile".to_string(),
            format!("{DESKTOP};{MOBILE}"),
        ];
        for value in invalid_lists {
            assert!(
                Config::parse(&with(&[("APPLE_CLIENT_ID", DESKTOP), ("APPLE_CLIENT_IDS", &value)])).is_err(),
                "{value:?}"
            );
        }
        for value in ["", " ", "*", "com..openarc", &format!("{DESKTOP},{MOBILE}")] {
            assert!(Config::parse(&with(&[("APPLE_CLIENT_ID", value)])).is_err(), "{value:?}");
        }
    }

    #[test]
    fn dotenv_values_are_literal_like_node_dotenv() {
        let parsed = parse_dotenv(
            "# comment\nJWT_SECRET=ab$cd$HOME\nexport HOST = 127.0.0.1 # local\nQUOTED=\"a\\nb # kept\"\nSINGLE='x\\ny'\nEMPTY=\nURL=postgres://u:p@h/db?sslmode=require\r\n",
        );
        let map: HashMap<String, String> = parsed.into_iter().collect();
        assert_eq!(map["JWT_SECRET"], "ab$cd$HOME");
        assert_eq!(map["HOST"], "127.0.0.1");
        assert_eq!(map["QUOTED"], "a\nb # kept");
        assert_eq!(map["SINGLE"], "x\\ny");
        assert_eq!(map["EMPTY"], "");
        assert_eq!(map["URL"], "postgres://u:p@h/db?sslmode=require");
    }

    #[test]
    fn requires_a_long_secret_and_a_valid_public_url() {
        let mut short = with(&[("APPLE_CLIENT_ID", DESKTOP)]);
        short.insert("JWT_SECRET".to_string(), "short".to_string());
        assert!(Config::parse(&short).is_err());
        assert!(
            Config::parse(&with(&[("APPLE_CLIENT_ID", DESKTOP), ("OPENARC_PUBLIC_BASE_URL", "not a url")])).is_err()
        );
        assert!(Config::parse(&with(&[("APPLE_CLIENT_ID", DESKTOP), ("PORT", "-1")])).is_err());
        let config = Config::parse(&with(&[("APPLE_CLIENT_ID", DESKTOP), ("PORT", " 0x1F90 ")])).unwrap();
        assert_eq!(config.port, 8080);
    }
}
