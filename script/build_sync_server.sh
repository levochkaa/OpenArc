#!/usr/bin/env bash
# Builds the Rust sync server for local test runs and prints its binary path.
# A Linux host without Rust builds it in the rust:1-bullseye Docker image; its
# older glibc keeps the binary runnable on the host.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Backend"
if ! command -v cargo >/dev/null 2>&1 && [[ -x /opt/homebrew/opt/rustup/bin/cargo ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if command -v cargo >/dev/null 2>&1; then
  cargo build --quiet --bin openarc-sync-server >&2
elif [[ "$(uname -s)" == Linux ]] && docker info >/dev/null 2>&1; then
  # The registry cache lives in target/, so the build leaves no Docker volume. The repository root is
  # mounted for Core/openarc-sync-protocol, which the server shares with the apps.
  docker run --rm --user "$(id -u):$(id -g)" --volume "$PWD/..:/src" --workdir /src/Backend \
    --env CARGO_HOME=/src/Backend/target/cargo-home rust:1-bullseye \
    cargo build --quiet --locked --bin openarc-sync-server >&2
else
  echo "The sync server needs Rust (cargo); install it with rustup." >&2
  exit 1
fi
echo "$PWD/target/debug/openarc-sync-server"
