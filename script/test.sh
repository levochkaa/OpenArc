#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET="${BAZEL_TEST_TARGET:-//:TheBrowserTests}"

case "$CONFIGURATION" in
  Debug)
    BAZEL_CONFIG="debug"
    ;;
  Release)
    BAZEL_CONFIG="release"
    ;;
  *)
    echo "error: unsupported CONFIGURATION '$CONFIGURATION' (expected Debug or Release)" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
mkdir -p "$HOME/.cache/bazel/thebrowser/disk" "$HOME/.cache/bazel/thebrowser/repository"

"$ROOT_DIR/script/chromium.sh" root "$CONFIGURATION" >/dev/null
bazel test --config="$BAZEL_CONFIG" "$TARGET"
