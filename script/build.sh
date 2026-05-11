#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="TheBrowser"
SCHEME="TheBrowser"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
APP_NAME="TheBrowser"
HELPER_NAME="TheBrowser Helper"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

validate_configuration() {
  case "$CONFIGURATION" in
    Debug|Release)
      ;;
    *)
      echo "error: unsupported CONFIGURATION '$CONFIGURATION' (expected Debug or Release)" >&2
      exit 2
      ;;
  esac
}

filter_xcodebuild_output() {
  # Xcode 26 still runs AppIntents metadata extraction for Swift app targets
  # and logs this warning even when metadata generation is explicitly disabled.
  sed '/warning: Metadata extraction disabled by --disable/d'
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

validate_configuration
"$ROOT_DIR/script/generate_xcodeproj.sh"
"$ROOT_DIR/script/chromium.sh" ensure "$CONFIGURATION" >/dev/null
clear_staged_runtime_artifacts

xcodebuild \
  -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | filter_xcodebuild_output

echo "TheBrowser built successfully"
