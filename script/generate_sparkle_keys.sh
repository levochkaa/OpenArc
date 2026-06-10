#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/sparkle_tools.sh"

ensure_sparkle_tools
"$SPARKLE_TOOLS_DIR/bin/generate_keys" "$@"
