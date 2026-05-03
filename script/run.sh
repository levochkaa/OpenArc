#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TheBrowser"
HELPER_NAME="TheBrowser Helper"
APP_BUNDLE_ID="com.levochkaa.TheBrowser"
CONFIGURATION="${CONFIGURATION:-Debug}"

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

kill_app() {
  /usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -TERM -f "$HELPER_NAME" >/dev/null 2>&1 || true

  for _ in {1..50}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1 && ! pgrep -f "$HELPER_NAME" >/dev/null 2>&1; then
      return
    fi

    sleep 0.1
  done

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
  local app_zip="$ROOT_DIR/bazel-bin/$APP_NAME.zip"
  local staging_dir="$ROOT_DIR/.build/bazel-run/$CONFIGURATION"
  local app_bundle="$staging_dir/$APP_NAME.app"
  local stamp_file="$staging_dir/.$APP_NAME.zip.stamp"

  if [[ ! -f "$app_zip" ]]; then
    echo "error: app archive not found at $app_zip" >&2
    exit 1
  fi

  local zip_stamp
  zip_stamp="$(stat -f "%m:%z" "$app_zip")"
  if [[ -d "$app_bundle" && -f "$stamp_file" ]] &&
     [[ "$(cat "$stamp_file")" == "$zip_stamp" ]]; then
    printf '%s\n' "$app_bundle"
    return
  fi

  echo "Staging $APP_NAME.app from $app_zip" >&2
  rm -rf "$app_bundle"
  mkdir -p "$staging_dir"
  /usr/bin/ditto -x -k "$app_zip" "$staging_dir"
  printf '%s\n' "$zip_stamp" > "$stamp_file"

  printf '%s\n' "$app_bundle"
}

build_app() {
  "$ROOT_DIR/script/build.sh"
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
    lldb -- "$(app_bundle_path)/Contents/MacOS/$APP_NAME"
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
