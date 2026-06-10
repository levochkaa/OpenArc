#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"
PROJECT_NAME="TheBrowser"
SCHEME="TheBrowser"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
APP_NAME="TheBrowser"
HELPER_NAME="TheBrowser Helper"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-YES}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-7Z2WHPKU8W}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-YES}"
ALLOW_PROVISIONING_DEVICE_REGISTRATION="${ALLOW_PROVISIONING_DEVICE_REGISTRATION:-YES}"
FULL_OUTPUT=0

usage() {
  cat <<'EOF'
Usage: ./script/build.sh [--full-output|--verbose]

By default, build output is filtered to error and warning lines. Pass
--full-output or --verbose to print the complete command output.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-output|--verbose)
      FULL_OUTPUT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

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

filter_build_output() {
  if [[ "$FULL_OUTPUT" == "1" ]]; then
    cat
    return
  fi

  # Xcode 26 still runs AppIntents metadata extraction for Swift app targets
  # and logs this warning even when metadata generation is explicitly disabled.
  sed '/warning: Metadata extraction disabled by --disable/d' | grep -En "error:|warning:" || true
}

run_with_filtered_output() {
  if [[ "$FULL_OUTPUT" == "1" ]]; then
    "$@"
    return
  fi

  set +e
  "$@" 2>&1 | filter_build_output
  local command_status=${PIPESTATUS[0]}
  set -e

  if [[ "$command_status" -ne 0 ]]; then
    echo "error: command failed: $*" >&2
  fi

  return "$command_status"
}

resolve_swift_packages() {
  run_with_filtered_output xcrun swift package --package-path "$ROOT_DIR" --disable-keychain resolve

  run_with_filtered_output xcodebuild \
    -resolvePackageDependencies \
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -packageAuthorizationProvider netrc \
    -scmProvider system \
    -skipPackagePluginValidation \
    -skipMacroValidation
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
source "$ROOT_DIR/script/sparkle_tools.sh"
run_with_filtered_output ensure_sparkle_tools
run_with_filtered_output "$ROOT_DIR/script/generate_xcodeproj.sh"
resolve_swift_packages
run_with_filtered_output "$ROOT_DIR/script/chromium.sh" ensure "$CONFIGURATION"
clear_staged_runtime_artifacts

xcodebuild_args=(
  -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "platform=macOS,arch=arm64" \
  -packageAuthorizationProvider netrc \
  -scmProvider system \
  -skipPackagePluginValidation \
  -skipMacroValidation \
)

if [[ "$CODE_SIGNING_ALLOWED" == "YES" && "$CODE_SIGN_STYLE" == "Automatic" ]]; then
  if [[ "$ALLOW_PROVISIONING_UPDATES" == "YES" ]]; then
    xcodebuild_args+=(-allowProvisioningUpdates)
  fi
  if [[ "$ALLOW_PROVISIONING_DEVICE_REGISTRATION" == "YES" ]]; then
    xcodebuild_args+=(-allowProvisioningDeviceRegistration)
  fi
fi

xcodebuild_args+=(
  "CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED"
  "CODE_SIGNING_REQUIRED=$CODE_SIGNING_REQUIRED"
  "CODE_SIGN_STYLE=$CODE_SIGN_STYLE"
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  xcodebuild_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

run_with_filtered_output xcodebuild "${xcodebuild_args[@]}" build

if [[ "$FULL_OUTPUT" == "1" ]]; then
  echo "TheBrowser built successfully"
fi
