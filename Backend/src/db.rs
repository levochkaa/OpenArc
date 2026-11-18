//! PostgreSQL pool and migrations. `DATABASE_URL` keeps node-postgres's
//! meaning: its SSL modes and certificate files, `PG*` variables for parts the
//! URL leaves out, and unknown parameters ignored.

use anyhow::{Context, bail};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use std::sync::Arc;
use std::time::Duration;
use tokio_postgres::config::SslMode;

/// Migrations in name order; each applies once, all in one transaction.
const MIGRATIONS: &[(&str, &str)] = &[
    ("001_init.sql", include_str!("../migrations/001_init.sql")),
    ("002_sync_tombstones.sql", include_str!("../migrations/002_sync_tombstones.sql")),
    ("003_sync_mutation_receipts.sql", include_str!("../migrations/003_sync_mutation_receipts.sql")),
    ("004_pinned_tab_urls.sql", include_str!("../migrations/004_pinned_tab_urls.sql")),
    ("005_sync_folders.sql", include_str!("../migrations/005_sync_folders.sql")),
    ("006_sync_expiry.sql", include_str!("../migrations/006_sync_expiry.sql")),
    ("007_sign_in_methods.sql", include_str!("../migrations/007_sign_in_methods.sql")),
    ("008_sync_boosts.sql", include_str!("../migrations/008_sync_boosts.sql")),
    ("009_shares.sql", include_str!("../migrations/009_shares.sql")),
];

/// Connections idle this long are closed, as node-postgres did, so a proxy
/// or NAT that drops idle connections never hands out a dead one.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// URL parameters tokio-postgres understands; node-postgres ignored others.
const PASSED_PARAMETERS: &[&str] = &[
    "user",
    "password",
    "dbname",
    "host",
    "hostaddr",
    "port",
    "options",
    "application_name",
    "connect_timeout",
    "tcp_user_timeout",
    "keepalives",
    "keepalives_idle",
    "keepalives_interval",
    "keepalives_retries",
    "target_session_attrs",
    "channel_binding",
    "load_balance_hosts",
];

#[derive(Debug, PartialEq)]
enum Tls {
    Disabled,
    /// Certificates checked against the web PKI roots or `sslrootcert`.
    Verified,
    /// `sslmode=no-verify`, or libpq's `require` with `uselibpqcompat=true`.
    Unverified,
}

#[derive(Debug)]
struct ConnectionOptions {
    url: String,
    tls: Tls,
    root_certificate: Option<String>,
    client_certificate: Option<(String, String)>,
}

impl ConnectionOptions {
    fn parse(database_url: &str, environment: impl Fn(&str) -> Option<String>) -> anyhow::Result<Self> {
        let (base, query) = database_url.split_once('?').unwrap_or((database_url, ""));
        let mut kept = Vec::new();
        let mut values: Vec<(String, String)> = Vec::new();
        for pair in query.split('&').filter(|pair| !pair.is_empty()) {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            let value = percent_decode(value);
            if PASSED_PARAMETERS.contains(&key) {
                kept.push(pair.to_string());
            }
            values.push((key.to_string(), value));
        }
        let value = |name: &str| values.iter().rev().find(|(key, _)| key == name).map(|(_, value)| value.clone());
        let ssl_flag = value("ssl").filter(|flag| matches!(flag.as_str(), "true" | "1")).map(|_| "require".to_string());
        let mode = value("sslmode").or(ssl_flag).or_else(|| environment("PGSSLMODE"));
        let libpq = value("uselibpqcompat").as_deref() == Some("true");
        let tls = match mode.as_deref() {
            None | Some("disable") => Tls::Disabled,
            Some("no-verify") => Tls::Unverified,
            Some("prefer" | "require") if libpq => Tls::Unverified,
            Some("prefer" | "require" | "verify-ca" | "verify-full") => Tls::Verified,
            Some(other) => bail!("unsupported sslmode {other:?} in DATABASE_URL"),
        };
        let url = if kept.is_empty() { base.to_string() } else { format!("{base}?{}", kept.join("&")) };
        let client_certificate = value("sslcert").zip(value("sslkey"));
        Ok(Self { url, tls, root_certificate: value("sslrootcert"), client_certificate })
    }

    fn config(&self, environment: impl Fn(&str) -> Option<String>) -> anyhow::Result<tokio_postgres::Config> {
        let mut config: tokio_postgres::Config = self.url.parse().context("invalid DATABASE_URL")?;
        if config.get_user().is_none()
            && let Some(user) = environment("PGUSER").or_else(|| environment("USER"))
        {
            config.user(user);
        }
        if config.get_password().is_none()
            && let Some(password) = environment("PGPASSWORD")
        {
            config.password(password);
        }
        if config.get_hosts().is_empty() {
            config.host(environment("PGHOST").unwrap_or_else(|| "localhost".to_string()));
        }
        if config.get_ports().is_empty()
            && let Some(port) = environment("PGPORT").and_then(|port| port.parse().ok())
        {
            config.port(port);
        }
        if config.get_dbname().is_none()
            && let Some(database) = environment("PGDATABASE")
        {
            config.dbname(database);
        }
        config.ssl_mode(if self.tls == Tls::Disabled { SslMode::Disable } else { SslMode::Require });
        Ok(config)
    }

    fn tls_config(&self) -> anyhow::Result<rustls::ClientConfig> {
        let builder = rustls::ClientConfig::builder();
        let builder = if self.tls == Tls::Unverified {
            let provider = rustls::crypto::CryptoProvider::get_default()
                .cloned()
                .unwrap_or_else(|| Arc::new(rustls::crypto::ring::default_provider()));
            builder.dangerous().with_custom_certificate_verifier(Arc::new(AcceptAnyCertificate(provider)))
        } else {
            let mut roots = rustls::RootCertStore::empty();
            match &self.root_certificate {
                Some(path) => {
                    for certificate in
                        CertificateDer::pem_file_iter(path).with_context(|| format!("sslrootcert {path}"))?
                    {
                        roots.add(certificate?)?;
                    }
                }
                None => roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned()),
            }
            builder.with_root_certificates(roots)
        };
        Ok(match &self.client_certificate {
            Some((certificate, key)) => {
                let chain = CertificateDer::pem_file_iter(certificate)
                    .with_context(|| format!("sslcert {certificate}"))?
                    .collect::<Result<Vec<_>, _>>()?;
                let key = PrivateKeyDer::from_pem_file(key).with_context(|| format!("sslkey {key}"))?;
                builder.with_client_auth_cert(chain, key)?
            }
            None => builder.with_no_client_auth(),
        })
    }
}

/// Ten connections, as before.
pub fn pool(database_url: &str) -> anyhow::Result<Pool> {
    let environment = |name: &str| std::env::var(name).ok();
    let options = ConnectionOptions::parse(database_url, environment)?;
    let config = options.config(environment)?;
    let manager_config = ManagerConfig { recycling_method: RecyclingMethod::Fast };
    let manager = if options.tls == Tls::Disabled {
        Manager::from_config(config, tokio_postgres::NoTls, manager_config)
    } else {
        let tls = tokio_postgres_rustls::MakeRustlsConnect::new(options.tls_config()?);
        Manager::from_config(config, tls, manager_config)
    };
    Ok(Pool::builder(manager).max_size(10).build()?)
}

/// Closes connections idle longer than [`IDLE_TIMEOUT`], every few seconds.
pub fn close_idle_connections(pool: Pool) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(5));
        loop {
            interval.tick().await;
            pool.retain(|_, metrics| metrics.last_used() < IDLE_TIMEOUT);
        }
    });
}

pub async fn migrate(pool: &Pool) -> anyhow::Result<()> {
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    tx.batch_execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
           name text PRIMARY KEY,
           applied_at timestamptz NOT NULL DEFAULT now()
         )",
    )
    .await?;
    for (name, sql) in MIGRATIONS {
        let applied = tx.query_opt("SELECT 1 FROM schema_migrations WHERE name = $1", &[name]).await?;
        if applied.is_some() {
            continue;
        }
        tx.batch_execute(sql).await.with_context(|| format!("migration {name} failed"))?;
        tx.execute("INSERT INTO schema_migrations (name) VALUES ($1)", &[name]).await?;
        println!("applied {name}");
    }
    tx.commit().await?;
    Ok(())
}

fn percent_decode(text: &str) -> String {
    url::form_urlencoded::parse(format!("v={text}").as_bytes())
        .next()
        .map(|(_, value)| value.into_owned())
        .unwrap_or_default()
}

/// `sslmode=no-verify`: encrypt without checking the certificate, while the
/// handshake signatures are still verified.
#[derive(Debug)]
struct AcceptAnyCertificate(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            certificate,
            signature,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            certificate,
            signature,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn migrations_cover_every_file_in_order() {
        let mut files: Vec<String> = std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/migrations"))
            .unwrap()
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter(|name| name.ends_with(".sql"))
            .collect();
        files.sort();
        assert_eq!(MIGRATIONS.iter().map(|(name, _)| (*name).to_string()).collect::<Vec<_>>(), files);
    }

    fn parse(url: &str, environment: &[(&str, &str)]) -> anyhow::Result<ConnectionOptions> {
        let environment: HashMap<String, String> =
            environment.iter().map(|(key, value)| ((*key).to_string(), (*value).to_string())).collect();
        ConnectionOptions::parse(url, |name| environment.get(name).cloned())
    }

    #[test]
    fn ssl_modes_follow_node_postgres() {
        let tls = |url: &str| parse(url, &[]).unwrap().tls;
        assert_eq!(tls("postgres://a@h/db"), Tls::Disabled);
        assert_eq!(tls("postgres://a@h/db?sslmode=disable"), Tls::Disabled);
        for mode in ["prefer", "require", "verify-ca", "verify-full"] {
            assert_eq!(tls(&format!("postgres://a@h/db?sslmode={mode}")), Tls::Verified, "{mode}");
        }
        assert_eq!(tls("postgres://a@h/db?ssl=true"), Tls::Verified);
        assert_eq!(tls("postgres://a@h/db?sslmode=no-verify"), Tls::Unverified);
        assert_eq!(tls("postgres://a@h/db?sslmode=require&uselibpqcompat=true"), Tls::Unverified);
        assert_eq!(parse("postgres://a@h/db", &[("PGSSLMODE", "require")]).unwrap().tls, Tls::Verified);
        assert!(parse("postgres://a@h/db?sslmode=sometimes", &[]).is_err());
    }

    #[test]
    fn node_postgres_only_parameters_are_removed_and_files_kept() {
        let options = parse(
            "postgres://a@h/db?sslmode=require&sslrootcert=%2Ftmp%2Fca.pem&sslcert=c.pem&sslkey=k.pem&application_name=sync&foo=1",
            &[],
        )
        .unwrap();
        assert_eq!(options.url, "postgres://a@h/db?application_name=sync");
        assert_eq!(options.root_certificate.as_deref(), Some("/tmp/ca.pem"));
        assert_eq!(options.client_certificate, Some(("c.pem".to_string(), "k.pem".to_string())));
    }

    #[test]
    fn missing_parts_come_from_pg_variables() {
        let options = parse("postgres:///?sslmode=disable", &[]).unwrap();
        let environment: HashMap<&str, &str> = HashMap::from([
            ("PGUSER", "sync"),
            ("PGPASSWORD", "secret$"),
            ("PGHOST", "db"),
            ("PGPORT", "6543"),
            ("PGDATABASE", "browser"),
        ]);
        let config = options.config(|name| environment.get(name).map(|value| (*value).to_string())).unwrap();
        assert_eq!(config.get_user(), Some("sync"));
        assert_eq!(config.get_password(), Some(&b"secret$"[..]));
        assert_eq!(config.get_ports(), &[6543]);
        assert_eq!(config.get_dbname(), Some("browser"));
        let explicit = parse("postgres://u:p@h:1/d", &[]).unwrap().config(|_| Some("other".to_string())).unwrap();
        assert_eq!(explicit.get_user(), Some("u"));
        assert_eq!(explicit.get_dbname(), Some("d"));
    }
}
