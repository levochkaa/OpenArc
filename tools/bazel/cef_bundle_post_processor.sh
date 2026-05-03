#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_ROOT="${1:?missing archive root}"
APP_BUNDLE="$ARCHIVE_ROOT/TheBrowser.app"
HELPER_NAME="TheBrowser Helper"
FRAMEWORK_ROOT="$APP_BUNDLE/Contents/Frameworks/Chromium Embedded Framework.framework"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

move_root_dylibs_to_version() {
  local framework_root="$1"
  local version_root="$2"
  local dylib

  while IFS= read -r -d '' dylib; do
    mv "$dylib" "$version_root/$(basename "$dylib")"
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
  local app_name="${HELPER_NAME}${name_suffix}"
  local source_bundle="$FRAMEWORKS_DIR/${HELPER_NAME}.app"
  local variant_bundle="$FRAMEWORKS_DIR/${app_name}.app"
  local variant_binary_dir="$variant_bundle/Contents/MacOS"
  local variant_binary="$variant_binary_dir/${app_name}"
  local base_binary="$variant_binary_dir/${HELPER_NAME}"
  local plist="$variant_bundle/Contents/Info.plist"

  rm -rf "$variant_bundle"
  ditto "$source_bundle" "$variant_bundle"
  chmod -R u+w "$variant_bundle"
  mv "$base_binary" "$variant_binary"

  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.levochkaa.TheBrowser.helper${bundle_suffix}" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
}

if [[ -d "$FRAMEWORK_ROOT" ]]; then
  create_versioned_cef_framework "$FRAMEWORK_ROOT"
else
  echo "error: CEF framework not found at $FRAMEWORK_ROOT" >&2
  exit 1
fi

if [[ -f "$RESOURCES_DIR/CREDITS.html" ]]; then
  mv "$RESOURCES_DIR/CREDITS.html" "$RESOURCES_DIR/CEFCredits.html"
fi

if [[ ! -d "$FRAMEWORKS_DIR/${HELPER_NAME}.app" ]]; then
  echo "error: helper bundle not found at $FRAMEWORKS_DIR/${HELPER_NAME}.app" >&2
  exit 1
fi

chmod -R u+w "$FRAMEWORKS_DIR/${HELPER_NAME}.app"

create_helper_variant " (Alerts)" ".alerts"
create_helper_variant " (GPU)" ".gpu"
create_helper_variant " (Plugin)" ".plugin"
create_helper_variant " (Renderer)" ".renderer"
