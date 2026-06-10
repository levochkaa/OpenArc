#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-}"

if [[ -z "$APP_BUNDLE" ]]; then
  echo "error: missing app bundle path" >&2
  exit 2
fi

source "$ROOT_DIR/script/sparkle_tools.sh"
ensure_sparkle_tools

SPARKLE_FRAMEWORK="$SPARKLE_TOOLS_DIR/Sparkle.framework"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
DESTINATION="$FRAMEWORKS_DIR/Sparkle.framework"

signing_identity() {
  if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY:-}" != "-" ]]; then
      printf '%s\n' "$EXPANDED_CODE_SIGN_IDENTITY"
      return
    fi

    if [[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY:-}" != "-" ]]; then
      printf '%s\n' "$CODE_SIGN_IDENTITY"
      return
    fi
  fi

  printf '%s\n' "-"
}

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: missing Sparkle framework at $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

rm -rf "$DESTINATION"
mkdir -p "$FRAMEWORKS_DIR"
ditto "$SPARKLE_FRAMEWORK" "$DESTINATION"
/usr/bin/codesign --force --deep --sign "$(signing_identity)" --timestamp=none "$DESTINATION"
