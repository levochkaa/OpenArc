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
# A Developer ID provisioning profile. It lets the app keep Touch ID passkeys in
# its keychain group; without it the group is left out and passkeys fall back to
# a phone or security key. When unset, the first profile for the app's bundle
# ID that provisions all devices (a Developer ID profile) is used.
profile="${OPENARC_PROVISIONING_PROFILE:-}"
notary_profile="${OPENARC_NOTARY_PROFILE:-openarc-notary}"
app_entitlements="${OPENARC_APP_ENTITLEMENTS:-$ROOT_DIR/Support/OpenArc-Distribution.entitlements}"
frameworks="$app/Contents/Frameworks"

if [[ ! -d "$app" ]]; then
  echo "error: app bundle not found at $app" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$app_entitlements" >/dev/null 2>&1 \
  && [[ -z "$profile" || ! -f "$profile" ]]; then
  echo "error: set OPENARC_PROVISIONING_PROFILE to a profile that allows Sign in with Apple" >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
profile_plist="$(mktemp -t openarc-profile)"
entitlements_with_group="$(mktemp -t openarc-entitlements)"
trap 'rm -f "$profile_plist" "$entitlements_with_group"' EXIT

# Prints the profile's team when it is a Developer ID profile for this app.
developer_id_team() {
  /usr/bin/security cms -D -i "$1" >"$profile_plist" 2>/dev/null || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist" 2>/dev/null)" == true ]] || return 1
  local app_id team
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null)"
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist" 2>/dev/null)"
  [[ -n "$team" && "$app_id" == "$team.$bundle_id" ]] || return 1
  echo "$team"
}

if [[ -z "$profile" ]]; then
  for candidate in "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile; do
    if [[ -f "$candidate" ]] && developer_id_team "$candidate" >/dev/null; then
      profile="$candidate"
      break
    fi
  done
fi
if [[ -n "$profile" ]] && team="$(developer_id_team "$profile")"; then
  cp "$app_entitlements" "$entitlements_with_group"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $team.$bundle_id" \
    -c "Add :com.apple.developer.team-identifier string $team" \
    -c "Add :keychain-access-groups array" \
    -c "Add :keychain-access-groups:0 string $team.$bundle_id.webauthn" \
    "$entitlements_with_group"
  app_entitlements="$entitlements_with_group"
  echo "Using Developer ID profile $profile"
elif ! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$app_entitlements" >/dev/null 2>&1; then
  echo "warning: no Developer ID provisioning profile for $bundle_id; Touch ID passkeys stay off" >&2
fi

sign() {
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$@"
}

cef="$frameworks/Chromium Embedded Framework.framework"
for library in "$cef/Versions/A/Libraries/"*.dylib; do
  sign "$library"
done
sign "$cef"

# The Chrome engine (script/chrome_engine.sh), when the build carries it: its libraries and helpers
# first, the renderer and GPU helpers with the same entitlements as CEF's, then the framework.
engine="$frameworks/OpenArc Framework.framework"
if [[ -d "$engine" ]]; then
  engine_version="$engine/Versions/Current"
  for library in "$engine_version/Libraries/"*.dylib; do
    [[ -e "$library" ]] && sign "$library"
  done
  for helper in "$engine_version/Helpers/"*.app; do
    case "$(basename "$helper")" in
      *" Renderer).app" | *"(Renderer).app") sign --entitlements "$ROOT_DIR/Support/OpenArcHelper-Renderer.entitlements" "$helper" ;;
      *" GPU).app" | *"(GPU).app") sign --entitlements "$ROOT_DIR/Support/OpenArcHelper-GPU.entitlements" "$helper" ;;
      *) sign "$helper" ;;
    esac
  done
  for tool in "$engine_version/Helpers/"*; do
    [[ -f "$tool" && -x "$tool" ]] && sign "$tool"
  done
  sign "$engine"
fi

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
sign "$app/Contents/Resources/bin/openarc"
for plugin in "$app/Contents/PlugIns/"*; do
  [[ -e "$plugin" ]] || continue
  sign "$plugin"
done

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
trap 'rm -rf "$work_dir"; rm -f "$profile_plist" "$entitlements_with_group"' EXIT
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
