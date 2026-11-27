//! OpenArc's platform-neutral browser logic. Every app calls it through UniFFI: Swift on macOS and iOS, and
//! later Kotlin on Android and C++ inside Chromium. See `docs/rust-core.md`.

uniffi::setup_scaffolding!("openarc_core");

pub mod sync;
pub mod web;
