#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-Debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_ROOT="$ROOT_DIR/ThirdParty/cef/current"
DEFAULT_PRODUCTS_DIR="$ROOT_DIR/.build/xcode/Build/Products/$CONFIGURATION"
APP_BUNDLE="${2:-$DEFAULT_PRODUCTS_DIR/TheBrowser.app}"
HELPER_BUNDLE="${3:-$DEFAULT_PRODUCTS_DIR/TheBrowser Helper.app}"
APP_FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
APP_RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
CEF_FRAMEWORK_SOURCE="$CEF_ROOT/$CONFIGURATION/Chromium Embedded Framework.framework"
CEF_FRAMEWORK_DEST="$APP_FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
HELPER_DEST="$APP_FRAMEWORKS_DIR/TheBrowser Helper.app"
RESOURCE_HELPER_DEST="$APP_RESOURCES_DIR/TheBrowser Helper.app"

create_versioned_cef_framework() {
  local framework_root="$1"
  local versions_dir="$framework_root/Versions"
  local version_root="$versions_dir/A"

  if [[ -d "$version_root" ]]; then
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
}

create_helper_variant() {
  local name_suffix="$1"
  local bundle_suffix="$2"
  local app_name="TheBrowser Helper${name_suffix}"
  local variant_bundle="$APP_FRAMEWORKS_DIR/${app_name}.app"
  local variant_binary_dir="$variant_bundle/Contents/MacOS"
  local variant_binary="$variant_binary_dir/${app_name}"
  local base_binary="$variant_binary_dir/TheBrowser Helper"
  local plist="$variant_bundle/Contents/Info.plist"

  rm -rf "$variant_bundle"
  ditto "$HELPER_BUNDLE" "$variant_bundle"
  mv "$base_binary" "$variant_binary"

  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.levochkaa.TheBrowser.helper${bundle_suffix}" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
}

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -d "$HELPER_BUNDLE" ]]; then
  echo "error: helper bundle not found at $HELPER_BUNDLE" >&2
  exit 1
fi

if [[ ! -d "$CEF_FRAMEWORK_SOURCE" ]]; then
  echo "error: CEF framework not found at $CEF_FRAMEWORK_SOURCE" >&2
  echo "Run ./script/chromium.sh ensure $CONFIGURATION first." >&2
  exit 1
fi

mkdir -p "$APP_FRAMEWORKS_DIR"
rm -rf "$CEF_FRAMEWORK_DEST" "$HELPER_DEST"
rm -rf "$RESOURCE_HELPER_DEST"
rm -rf "$APP_FRAMEWORKS_DIR/TheBrowser Helper (Alerts).app"
rm -rf "$APP_FRAMEWORKS_DIR/TheBrowser Helper (GPU).app"
rm -rf "$APP_FRAMEWORKS_DIR/TheBrowser Helper (Plugin).app"
rm -rf "$APP_FRAMEWORKS_DIR/TheBrowser Helper (Renderer).app"

ditto "$CEF_FRAMEWORK_SOURCE" "$CEF_FRAMEWORK_DEST"
create_versioned_cef_framework "$CEF_FRAMEWORK_DEST"
ditto "$HELPER_BUNDLE" "$HELPER_DEST"

create_helper_variant " (Alerts)" ".alerts"
create_helper_variant " (GPU)" ".gpu"
create_helper_variant " (Plugin)" ".plugin"
create_helper_variant " (Renderer)" ".renderer"
