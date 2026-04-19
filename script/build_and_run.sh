#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TheBrowser"
HELPER_NAME="TheBrowser Helper"
APP_BUNDLE_ID="com.levochkaa.TheBrowser"
PROJECT_NAME="TheBrowser"
SCHEME="TheBrowser"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_BINARY="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$HELPER_NAME.app/Contents/MacOS/$HELPER_NAME"

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

clear_staged_runtime_artifacts() {
  local frameworks_dir="$APP_BUNDLE/Contents/Frameworks"
  local resources_dir="$APP_BUNDLE/Contents/Resources"

  rm -rf \
    "$frameworks_dir/Chromium Embedded Framework.framework" \
    "$frameworks_dir/$HELPER_NAME.app" \
    "$frameworks_dir/${HELPER_NAME} (Alerts).app" \
    "$frameworks_dir/${HELPER_NAME} (GPU).app" \
    "$frameworks_dir/${HELPER_NAME} (Plugin).app" \
    "$frameworks_dir/${HELPER_NAME} (Renderer).app" \
    "$resources_dir/$HELPER_NAME.app"
}

generate_project() {
  "$ROOT_DIR/script/generate_xcodeproj.sh"
}

ensure_chromium() {
  "$ROOT_DIR/script/chromium.sh" ensure "$CONFIGURATION"
}

build_app() {
  clear_staged_runtime_artifacts
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS,arch=arm64" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
}

stage_embedded_chromium() {
  "$ROOT_DIR/script/stage_cef_bundle.sh" "$CONFIGURATION"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"

  for _ in {1..50}; do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      /usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
      return
    fi

    sleep 0.1
  done
}

usage() {
  echo "usage: $0 [run|build|debug|logs|telemetry|verify]" >&2
  exit 2
}

run_default_flow() {
  kill_app
  generate_project
  ensure_chromium
  build_app
  stage_embedded_chromium
}

case "$MODE" in
  run)
    run_default_flow
    open_app
    ;;
  build)
    run_default_flow
    echo "$APP_NAME built successfully"
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
  --verify|verify)
    run_default_flow
    open_app
    sleep 3
    pgrep -x "$APP_NAME" >/dev/null
    pgrep -x "$HELPER_NAME" >/dev/null
    echo "$APP_NAME launched successfully"
    ;;
  *)
    usage
    ;;
esac
