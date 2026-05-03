#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET="${BAZEL_TARGET:-//:TheBrowser}"

source "$ROOT_DIR/script/bazel_environment.sh"
configure_bazel_environment

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

"$ROOT_DIR/script/chromium.sh" root "$CONFIGURATION" >/dev/null
bazel build "${BAZEL_BUILD_ARGS[@]}" --config="$BAZEL_CONFIG" "$TARGET"

echo "TheBrowser built successfully"
