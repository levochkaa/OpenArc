#!/usr/bin/env bash
set -euo pipefail

CEF_CONFIGURATION="${1:-Release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_ROOT="$ROOT_DIR/ThirdParty/cef/current"
CHROMIUM_FORK_MARKER="$CEF_ROOT/.openarc-chromium-fork"
APP_CONFIGURATION="${CONFIGURATION:-Debug}"
DEFAULT_PRODUCTS_DIR="$ROOT_DIR/.build/xcode/Build/Products/$APP_CONFIGURATION"
APP_BUNDLE="${2:-$DEFAULT_PRODUCTS_DIR/OpenArc.app}"
HELPER_BUNDLE="${3:-$DEFAULT_PRODUCTS_DIR/OpenArc Helper.app}"
APP_FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
APP_RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
DEFAULT_APP_ENTITLEMENTS="Support/OpenArc.entitlements"
if [[ "$APP_CONFIGURATION" == "Debug" ]]; then
  DEFAULT_APP_ENTITLEMENTS="Support/OpenArc-Debug.entitlements"
fi
APP_ENTITLEMENTS="${CODE_SIGN_ENTITLEMENTS:-$DEFAULT_APP_ENTITLEMENTS}"
if [[ "$APP_ENTITLEMENTS" != /* ]]; then
  APP_ENTITLEMENTS="$ROOT_DIR/$APP_ENTITLEMENTS"
fi
CEF_FRAMEWORK_SOURCE="$CEF_ROOT/$CEF_CONFIGURATION/Chromium Embedded Framework.framework"
CEF_FRAMEWORK_DEST="$APP_FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
SPARKLE_FRAMEWORK_DEST="$APP_FRAMEWORKS_DIR/Sparkle.framework"
SENTRY_FRAMEWORK_DEST="$APP_FRAMEWORKS_DIR/Sentry.framework"
HELPER_DEST="$APP_FRAMEWORKS_DIR/OpenArc Helper.app"
RESOURCE_HELPER_DEST="$APP_RESOURCES_DIR/OpenArc Helper.app"

validate_cef_configuration() {
  case "$CEF_CONFIGURATION" in
    Debug|Release)
      ;;
    *)
      echo "error: unsupported CEF runtime configuration '$CEF_CONFIGURATION' (expected Debug or Release)" >&2
      exit 2
      ;;
  esac
}

move_root_dylibs_to_version() {
  local framework_root="$1"
  local version_root="$2"
  local dylib

  while IFS= read -r -d '' dylib; do
    local destination="$version_root/$(basename "$dylib")"
    if [[ ! -e "$dylib" ]]; then
      continue
    fi

    if ! mv "$dylib" "$destination"; then
      if [[ -e "$destination" && ! -e "$dylib" ]]; then
        continue
      fi

      return 1
    fi
  done < <(find "$framework_root" -maxdepth 1 -type f -name "*.dylib" -print0)
}

create_versioned_cef_framework() {
  local framework_root="$1"
  local versions_dir="$framework_root/Versions"
  local version_root="$versions_dir/A"

  if [[ -d "$version_root" ]]; then
    move_root_dylibs_to_version "$framework_root" "$version_root"
    return
  fi

  mkdir -p "$version_root"
  mv "$framework_root/Chromium Embedded Framework" "$version_root/Chromium Embedded Framework"
  mv "$framework_root/Libraries" "$version_root/Libraries"
  mv "$framework_root/Resources" "$version_root/Resources"

  ln -sfn A "$versions_dir/Current"
  ln -sfn "Versions/Current/Chromium Embedded Framework" "$framework_root/Chromium Embedded Framework"
  ln -sfn "Versions/Current/Libraries" "$framework_root/Libraries"
  ln -sfn "Versions/Current/Resources" "$framework_root/Resources"

  move_root_dylibs_to_version "$framework_root" "$version_root"
}

create_helper_variant() {
  local name_suffix="$1"
  local bundle_suffix="$2"
  local app_name="OpenArc Helper${name_suffix}"
  local variant_bundle="$APP_FRAMEWORKS_DIR/${app_name}.app"
  local variant_binary_dir="$variant_bundle/Contents/MacOS"
  local variant_binary="$variant_binary_dir/${app_name}"
  local base_binary="$variant_binary_dir/OpenArc Helper"
  local plist="$variant_bundle/Contents/Info.plist"

  rm -rf "$variant_bundle"
  ditto "$HELPER_BUNDLE" "$variant_bundle"
  mv "$base_binary" "$variant_binary"

  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.levochkaa.OpenArc.helper${bundle_suffix}" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"

  # macOS sets one default notification style per bundle. As in Chromium, the
  # main app shows banners and this helper shows notifications that stay until
  # dismissed, under the app's own name.
  if [[ "$name_suffix" == " (Alerts)" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName OpenArc" "$plist"
    /usr/libexec/PlistBuddy -c "Add :NSUserNotificationAlertStyle string alert" "$plist"
  fi
}

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

sign_app_bundle() {
  local identity
  identity="$(signing_identity)"

  if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
    echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2
    exit 1
  fi

  # The CEF runtime is copied after Xcode's normal dependency processing, so
  # seal nested code here using the active Xcode identity when available.
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$CEF_FRAMEWORK_DEST"
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$HELPER_DEST"
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$APP_FRAMEWORKS_DIR/OpenArc Helper (Alerts).app"
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$APP_FRAMEWORKS_DIR/OpenArc Helper (GPU).app"
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$APP_FRAMEWORKS_DIR/OpenArc Helper (Plugin).app"
  /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$APP_FRAMEWORKS_DIR/OpenArc Helper (Renderer).app"
  if [[ -d "$SPARKLE_FRAMEWORK_DEST" ]]; then
    /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none "$SPARKLE_FRAMEWORK_DEST"
  fi
  if [[ -d "$SENTRY_FRAMEWORK_DEST" ]]; then
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$SENTRY_FRAMEWORK_DEST"
  fi
  # The Dock tile plug-in, which Xcode embeds and signs, is sealed again with this identity.
  local plugin
  for plugin in "$APP_BUNDLE/Contents/PlugIns/"*; do
    [[ -e "$plugin" ]] || continue
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$plugin"
  done
  # Xcode has expanded its build settings in the .xcent file and added the identifiers
  # a profile needs. macOS kills an app signed with the raw file's keychain group.
  signing_entitlements="$APP_ENTITLEMENTS"
  processed_entitlements="${TARGET_TEMP_DIR:-}/${FULL_PRODUCT_NAME:-}.xcent"
  if [[ -f "$processed_entitlements" ]]; then
    signing_entitlements="$processed_entitlements"
  elif /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$APP_ENTITLEMENTS" >/dev/null 2>&1; then
    signing_entitlements="$(mktemp -t openarc-entitlements)"
    cp "$APP_ENTITLEMENTS" "$signing_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$signing_entitlements"
  fi
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --entitlements "$signing_entitlements" "$APP_BUNDLE"
}

validate_cef_configuration

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -d "$HELPER_BUNDLE" ]]; then
  echo "error: helper bundle not found at $HELPER_BUNDLE" >&2
  exit 1
fi

if [[ ! -f "$CHROMIUM_FORK_MARKER" ]]; then
  echo "error: OpenArc Chromium fork marker not found at $CHROMIUM_FORK_MARKER" >&2
  echo "Run ./script/chromium_source.sh package $CEF_CONFIGURATION first, then ./script/chromium.sh root $CEF_CONFIGURATION." >&2
  exit 1
fi

if [[ ! -d "$CEF_FRAMEWORK_SOURCE" ]]; then
  echo "error: CEF framework not found at $CEF_FRAMEWORK_SOURCE" >&2
  echo "Run ./script/chromium_source.sh package $CEF_CONFIGURATION first, then ./script/chromium.sh root $CEF_CONFIGURATION." >&2
  exit 1
fi

if [[ ! -f "$CEF_ROOT/CREDITS.html" ]]; then
  echo "error: CEF credits not found at $CEF_ROOT/CREDITS.html" >&2
  echo "Run ./script/chromium_source.sh package $CONFIGURATION first, then ./script/chromium.sh root $CONFIGURATION." >&2
  exit 1
fi

mkdir -p "$APP_FRAMEWORKS_DIR"
mkdir -p "$APP_RESOURCES_DIR"
rm -rf "$CEF_FRAMEWORK_DEST" "$HELPER_DEST"
rm -rf "$RESOURCE_HELPER_DEST"
rm -rf "$APP_FRAMEWORKS_DIR/OpenArc Helper (Alerts).app"
rm -rf "$APP_FRAMEWORKS_DIR/OpenArc Helper (GPU).app"
rm -rf "$APP_FRAMEWORKS_DIR/OpenArc Helper (Plugin).app"
rm -rf "$APP_FRAMEWORKS_DIR/OpenArc Helper (Renderer).app"

ditto "$CEF_FRAMEWORK_SOURCE" "$CEF_FRAMEWORK_DEST"
create_versioned_cef_framework "$CEF_FRAMEWORK_DEST"
/usr/bin/python3 "$(dirname "$0")/brand_cef_resources.py" "$CEF_FRAMEWORK_DEST" OpenArc
ditto "$HELPER_BUNDLE" "$HELPER_DEST"
ditto "$CEF_ROOT/CREDITS.html" "$APP_RESOURCES_DIR/CEFCredits.html"

create_helper_variant " (Alerts)" ".alerts"
create_helper_variant " (GPU)" ".gpu"
create_helper_variant " (Plugin)" ".plugin"
create_helper_variant " (Renderer)" ".renderer"

sign_app_bundle
