#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
SPARKLE_TOOLS_ROOT="${SPARKLE_TOOLS_ROOT:-$ROOT_DIR/.build/sparkle}"
SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_ROOT/Sparkle-$SPARKLE_VERSION"
SPARKLE_TOOLS_ARCHIVE="$SPARKLE_TOOLS_ROOT/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_TOOLS_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

ensure_sparkle_tools() {
  if [[ -x "$SPARKLE_TOOLS_DIR/bin/generate_appcast" && -x "$SPARKLE_TOOLS_DIR/bin/generate_keys" ]]; then
    return
  fi

  mkdir -p "$SPARKLE_TOOLS_DIR"
  if [[ ! -f "$SPARKLE_TOOLS_ARCHIVE" ]]; then
    curl -fL "$SPARKLE_TOOLS_URL" -o "$SPARKLE_TOOLS_ARCHIVE"
  fi

  tar -xJf "$SPARKLE_TOOLS_ARCHIVE" -C "$SPARKLE_TOOLS_DIR"
}
