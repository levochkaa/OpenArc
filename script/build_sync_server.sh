#!/usr/bin/env bash
# Builds the Rust sync server for local test runs and prints its binary path.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Backend"
if ! command -v cargo >/dev/null 2>&1 && [[ -x /opt/homebrew/opt/rustup/bin/cargo ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "The sync server needs Rust (cargo); install it with rustup." >&2
  exit 1
fi
cargo build --quiet --bin openarc-sync-server >&2
echo "$PWD/target/debug/openarc-sync-server"
