# Rust core

`Core/` holds OpenArc's platform-neutral browser logic in Rust. The Mac and iOS apps call it from Swift through
[UniFFI](https://github.com/mozilla/uniffi-rs); Android (Kotlin, through UniFFI) and the Windows and Linux apps
(C++ inside our Chromium fork, through `cxx` or the C ABI) will call the same code. The UI, view models, page
engines and system services (Keychain, file pickers) stay native on each platform.

## Layout

| Path | What it is |
| --- | --- |
| `Core/openarc-core` | The core: a `staticlib` with UniFFI exports. |
| `Core/openarc-sync-protocol` | Sync protocol constants: push versions, placements, batch and body limits, expiry intervals, boost limits. `Backend` depends on it too, so the server and the clients agree. |
| `Core/uniffi-bindgen` | The bindings generator, pinned to the core's UniFFI version. |
| `Sources/Core/Generated` | The Swift bindings, checked in: `openarc_core.swift`, `openarc_coreFFI.h`, `module.modulemap`. |
| `script/rust_core.sh` | Builds the library and keeps the bindings current. |

What the core does today:

- `web::navigation`: what the address bar does with typed text, an address or a search (`BrowserNavigationResolver`).
- `web::internal_urls`: `openarc://` pages and their `chrome://`, `arc://`, `dia://` aliases, and the addresses the
  Chrome engine loads and shows (`BrowserInternalURLNormalizer`, `BrowserChromeEngineInternalURLs`).
- `web::search_engine`: the engines of Settings ▸ Search and their results pages (`BrowserSearchEngine`).
- `web::display`: the short and full forms of an address in the toolbar and the sidebar (`BrowserURLDisplayFormatter`).
- `web::tracking`: tracking parameters Copy URL leaves out (`BrowserTrackingParameters`).
- `web::domain`: public suffixes and registrable domains from the Public Suffix List (`BrowserPublicSuffixDomainParser`,
  `BrowserFilterDomains`), which replaced the SwiftDomainParser package.
- `sync::outbox`: canonical v2 session entities, the server baseline with applied events, replay of queued push rows
  over it, and the resulting app session (`BrowserSyncOutboxProjection`, `BrowserSyncOutboxBaseline`). An ACK reuses
  the last replay instead of replaying the rest of the queue (`CoreSyncReplayMemo`, `BrowserSyncOutboxReplayMemo`).
- `sync::semantic` and `sync::folders`: protocol version 3 and 4 operations between two sessions, their replay over
  canonical values, and the v4 session with pinned folders (`BrowserSyncSemanticProjection`,
  `BrowserSyncFolderProjection`).
- `sync::dates`: activity dates on the wire as ISO 8601 strings (`BrowserSyncActivityDates`).
- `sync::model`: session and protocol records the projections read and write; the default Space's ID and icon
  (`BrowserSessionDefaults`).
- `sync` (module root): the protocol constants above, for `BrowserSyncService`, the expiry models, and boost records.

The Swift types in parentheses keep their API and call the core, so callers did not change.

## Addresses as Foundation spells them

`web::components` parses and rebuilds addresses by RFC 3986 with the rules of Apple's `URLComponents` on macOS 26:
characters a component does not allow are percent-encoded, a non-ASCII host is IDNA-encoded (UTS 46, nontransitional,
no STD3 rules), and a valid address stays byte for byte as typed (`https://Google.co`, no trailing slash added).
`web::ip` reads IP addresses as the Network framework does (`127.1`, `0x7f.1`, a zone after `%`). The WHATWG parser of
the `url` crate would canonicalize differently, and stored sessions, history and sync already hold Foundation's form.

`Core/openarc-core/tests/fixtures/web-addresses.json` records what the Swift code answered for 223 typed inputs,
103 addresses, 32 queries for every search engine and 52 hosts. `tests/web_addresses.rs` checks every function
against it. The fixture differs from the old Swift answers only where the Public Suffix List of the `psl` crate is
newer than SwiftDomainParser's (`home.arpa`, `*.bd`) or reads Punycode suffixes (`xn--p1ai`), and for hosts with an
empty label, which now have no registrable domain.

## Sync projections as Swift computed them

The app keeps its `Codable` types for SQLite and the wire; `Sources/Browser/BrowserSyncCoreBridge.swift` converts
them to the core's records and back. The JSON codecs stay in Swift for now.

Strings compare as Swift compares them (`sync::text`): by canonical equivalence, so a title or address that changed
only its Unicode normalization ("é" as `U+00E9` or as `e` + `U+0301`) is not an edit, and ties in sibling order break
by the NFC form. Identities (the keys of maps and sets) compare byte for byte. Swift's dictionaries merge two IDs
that differ only in normalization; the core keeps them apart.

`sync::dates` parses dates as `Date.ISO8601FormatStyle` in `swift-foundation` 6.2 does (the version macOS 26 and iOS
26 ship): it accepts `2026-02-30`, `T25:00:00`, `GMT+3`, and trailing text after the zone, counts days before 15
October 1582 in the Julian calendar, and runs the same floating-point steps so a parsed time matches `TimeInterval`
to the bit. Newer `swift-foundation` is stricter (it rejects `T25:00:00`); the core keeps the 6.2 behavior so results
no longer depend on the OS version. Dates are written as `ISO8601DateFormatter` writes them: whole seconds, UTC.

`Core/openarc-core/tests/fixtures/sync-projections.json.gz` holds 70 random sessions, edits, move intents, queues,
and server event streams in wire format, with Swift's answers for every projection, plus 88 date strings to parse
and 232 dates to compare, project or write. `src/sync/fixture_tests.rs` checks the Rust code against them. Before
the switch, it also passed 1,800 more cases; `OPENARC_SYNC_FIXTURES` names extra fixture files (comma-separated,
plain or gzip JSON) for such a run.

## Building

`script/rust_core.sh` finds cargo the way `script/build_sync_server.sh` does and installs a missing Rust target with
rustup. Install Rust with [rustup](https://rustup.rs); the script adds `aarch64-apple-darwin`, `aarch64-apple-ios` and
`aarch64-apple-ios-sim` itself.

- Xcode: every target with the `OpenArcCore` template in `project.yml` (the Mac app, the iOS app, both test bundles)
  runs the "Build Rust Core" phase, `script/rust_core.sh xcode`. It builds the release library for `PLATFORM_NAME`
  into `.build/rust-core/<platform>/libopenarc_core.a`, which `OPENARC_CORE_LDFLAGS` links, and rewrites the
  bindings when the Rust exports changed. Cargo runs without Xcode's environment, so an iOS `SDKROOT` does not reach
  the host's build scripts. Each checkout has its own cargo target directory, `.build/rust-core/target`.
- `script/rust_core.sh test` runs the Rust tests; `./build.sh test` runs the Swift tests that go through the core.
- `script/rust_core.sh check` fails when `Sources/Core/Generated` is stale.
- `script/rust_core.sh credits` rewrites the Rust crates section of `Sources/Browser/Resources/Credits.html` from
  `cargo tree` and the crates' license files. Run it after adding or updating a crate.

SwiftFormat skips `Sources/Core/Generated`.

## Adding to the core

1. Write the logic in `Core/openarc-core/src`, with Rust tests. Export what the apps call with
   `#[uniffi::export(name = "core_…")]` and name exported types `Core…`: the Swift bindings live in the app's module,
   so the prefix keeps them apart from the app's own names.
2. When the logic replaces Swift code, record the Swift answers first and check the Rust code against them, as
   `web-addresses.json` does.
3. Keep the Swift type's API and make it call the core, then run `./build.sh build` (it regenerates the bindings)
   and `./build.sh test`.
4. `script/rust_core.sh credits` when a crate was added.

## Next

The wire codecs come next: JSON for queue rows, events, and the baseline, so the core reads SQLite rows directly and
the app stops converting the whole baseline on every call. Then storage (`BrowserSQLiteSessionStore` on `GRDB` to
`rusqlite`) and the sync service's network loop (`BrowserSyncService`), then importers for other browsers' data. Each
step keeps the Swift API and checks the Rust code against recorded Swift answers.
