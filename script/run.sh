#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TheBrowser"
HELPER_NAME="TheBrowser Helper"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: unsupported CONFIGURATION '$CONFIGURATION' (expected Debug or Release)" >&2
    exit 2
    ;;
esac

kill_app() {
  # Dev relaunches should not drive CEF's graceful shutdown path: DCHECK aborts
  # there surface as crash reports when a new Run stops the old browser.
  pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -KILL -f "$HELPER_NAME" >/dev/null 2>&1 || true

  for _ in {1..50}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1 && ! pgrep -f "$HELPER_NAME" >/dev/null 2>&1; then
      return
    fi

    sleep 0.1
  done

  echo "error: failed to stop existing $APP_NAME processes" >&2
  exit 1
}

app_bundle_path() {
  printf '%s\n' "$APP_BUNDLE"
}

build_app() {
  "$ROOT_DIR/script/build.sh" --full-output
}

open_app() {
  local app_bundle
  app_bundle="$(app_bundle_path)"

  if [[ ! -d "$app_bundle" ]]; then
    echo "error: app bundle not found at $app_bundle" >&2
    exit 1
  fi

  echo "Launching $app_bundle"
  /usr/bin/open -n "$app_bundle" "$@"
}

usage() {
  echo "usage: $0 [run|debug|logs|telemetry]" >&2
  exit 2
}

run_default_flow() {
  kill_app
  build_app
}

case "$MODE" in
  run)
    run_default_flow
    open_app
    ;;
  --debug|debug)
    run_default_flow
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    run_default_flow
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    run_default_flow
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\" OR process == \"$HELPER_NAME\""
    ;;
  *)
    usage
    ;;
esac
