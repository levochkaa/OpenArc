//! OpenArc sync server: `openarc-sync-server [serve]` runs the API,
//! `openarc-sync-server migrate` applies pending migrations.

mod app;
#[cfg(test)]
mod app_tests;
mod auth;
mod body;
mod config;
mod db;
mod error;
mod js_json;
mod requests;
mod schema;
mod shares;
mod signin;
mod sync;
mod time;
mod updates;

use crate::app::{AppState, router};
use crate::auth::AuthService;
use crate::config::Config;
use crate::shares::ShareService;
use crate::signin::SignInService;
use crate::sync::SyncService;
use crate::updates::{GITHUB_API_URL, UpdatesService};
use std::process::ExitCode;
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

fn main() -> ExitCode {
    // Before the runtime starts any thread.
    config::load_dotenv();
    match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(run()),
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> ExitCode {
    let _ = rustls::crypto::ring::default_provider().install_default();
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with_writer(std::io::stderr)
        .init();

    let command = std::env::args().nth(1);
    let result = match command.as_deref() {
        None | Some("serve") => serve().await,
        Some("migrate") => migrate().await,
        Some(other) => {
            eprintln!("unknown command {other:?}; use `serve` or `migrate`");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

fn load_config() -> anyhow::Result<Config> {
    Config::from_env().map_err(|issues| anyhow::anyhow!("invalid configuration: {issues}"))
}

async fn migrate() -> anyhow::Result<()> {
    let config = load_config()?;
    let pool = db::pool(&config.database_url)?;
    db::migrate(&pool).await?;
    pool.close();
    Ok(())
}

async fn serve() -> anyhow::Result<()> {
    let config = Arc::new(load_config()?);
    let pool = db::pool(&config.database_url)?;
    db::close_idle_connections(pool.clone());
    // Like Node's fetch: no proxy from the environment, a generous read timeout.
    let http = reqwest::Client::builder()
        .no_proxy()
        .connect_timeout(std::time::Duration::from_secs(30))
        .read_timeout(std::time::Duration::from_secs(300))
        .build()?;
    let auth = AuthService::with_apple_keys_url(&config, http.clone(), &config.sign_in.endpoints.apple_keys);
    let state = AppState {
        sync: Arc::new(SyncService::new(pool.clone(), auth.clone())),
        sign_in: SignInService::new(pool.clone(), auth.clone(), config.clone(), http.clone())?,
        shares: Arc::new(ShareService::new(pool.clone(), &config.share_base_url)),
        updates: UpdatesService::new(config.clone(), http, GITHUB_API_URL),
        auth,
        config: config.clone(),
    };
    tokio::spawn(signin::clean_up_periodically(pool.clone()));
    let listener = TcpListener::bind((config.host.as_str(), config.port)).await?;
    let address = listener.local_addr()?;
    // Test harnesses read this line to find an ephemeral port.
    println!("OpenArc sync server listening on http://{address}");
    axum::serve(listener, router(state)).with_graceful_shutdown(shutdown_signal()).await?;
    pool.close();
    Ok(())
}

async fn shutdown_signal() {
    let interrupt = tokio::signal::ctrl_c();
    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("SIGTERM handler");
    tokio::select! {
        _ = interrupt => {}
        _ = terminate.recv() => {}
    }
}
