#!/usr/bin/env bash
# Signs a Release OpenArc.app for distribution outside the App Store with a
# Developer ID, the hardened runtime and secure timestamps, then optionally
# notarizes and staples it. Nested code is signed before what contains it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  printf 'Usage: %s APP_BUNDLE [--notarize]\n' "$0" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
app="$1"
shift
notarize=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize)
      notarize=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

identity="${OPENARC_SIGNING_IDENTITY:-Developer ID Application}"
# A Developer ID provisioning profile for the app's identifier; Sign in with
# Apple is a restricted entitlement that macOS only honors with one.
profile="${OPENARC_PROVISIONING_PROFILE:-}"
notary_profile="${OPENARC_NOTARY_PROFILE:-openarc-notary}"
app_entitlements="${OPENARC_APP_ENTITLEMENTS:-$ROOT_DIR/Support/OpenArc.entitlements}"
frameworks="$app/Contents/Frameworks"

if [[ ! -d "$app" ]]; then
  echo "error: app bundle not found at $app" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$app_entitlements" >/dev/null 2>&1 \
  && [[ -z "$profile" || ! -f "$profile" ]]; then
  echo "error: set OPENARC_PROVISIONING_PROFILE to the app's Developer ID provisioning profile" >&2
  exit 1
fi

sign() {
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$@"
}

cef="$frameworks/Chromium Embedded Framework.framework"
for library in "$cef/Versions/A/Libraries/"*.dylib; do
  sign "$library"
done
sign "$cef"

# Sparkle's documented order; Downloader keeps its own entitlements.
sparkle="$frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
  sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  sign "$sparkle/Versions/B/Autoupdate"
  sign "$sparkle/Versions/B/Updater.app"
  sign "$sparkle"
fi
if [[ -d "$frameworks/Sentry.framework" ]]; then
  sign "$frameworks/Sentry.framework"
fi

sign "$frameworks/OpenArc Helper.app"
sign "$frameworks/OpenArc Helper (Alerts).app"
sign "$frameworks/OpenArc Helper (Plugin).app"
sign --entitlements "$ROOT_DIR/Support/OpenArcHelper-GPU.entitlements" "$frameworks/OpenArc Helper (GPU).app"
sign --entitlements "$ROOT_DIR/Support/OpenArcHelper-Renderer.entitlements" "$frameworks/OpenArc Helper (Renderer).app"
sign "$app/Contents/Resources/OpenArc Web App Launcher"

# A development build embeds its development profile, which a Developer ID
# signature must not carry.
rm -f "$app/Contents/embedded.provisionprofile"
if [[ -n "$profile" ]]; then
  cp "$profile" "$app/Contents/embedded.provisionprofile"
fi
sign --entitlements "$app_entitlements" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "Signed $app with $identity"

if [[ "$notarize" != true ]]; then
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openarc-notarize.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/$(basename "$app" .app).zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
result="$work_dir/result.json"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait --output-format json >"$result"
status="$(/usr/bin/plutil -extract status raw -o - "$result")"
submission="$(/usr/bin/plutil -extract id raw -o - "$result")"
if [[ "$status" != "Accepted" ]]; then
  echo "error: notarization of $submission ended as $status" >&2
  xcrun notarytool log "$submission" --keychain-profile "$notary_profile" >&2 || true
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
echo "Notarized $app ($submission)"
