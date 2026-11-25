#!/usr/bin/env bash
# Packs OpenArc.app into a drag-to-Applications disk image: the app next to an
# Applications link, on a volume named OpenArc. With --sign the image gets the
# Developer ID signature script/sign_release_app.sh uses; with --notarize it is
# also notarized and stapled.
set -euo pipefail

usage() {
  printf 'Usage: %s APP_BUNDLE OUTPUT.dmg [--sign] [--notarize]\n' "$0" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
app="$1"
output="$2"
shift 2
sign=false
notarize=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)
      sign=true
      shift
      ;;
    --notarize)
      sign=true
      notarize=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

identity="${OPENARC_SIGNING_IDENTITY:-Developer ID Application}"
notary_profile="${OPENARC_NOTARY_PROFILE:-openarc-notary}"
volume_name="${OPENARC_DMG_VOLUME_NAME:-OpenArc}"

if [[ ! -d "$app" ]]; then
  echo "error: app bundle not found at $app" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openarc-dmg.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
staging="$work_dir/$volume_name"
mkdir -p "$staging" "$(dirname "$output")"
ditto "$app" "$staging/OpenArc.app"
ln -s /Applications "$staging/Applications"

rm -f "$output"
# ULFO (LZFSE) opens on macOS 10.11 and later, well below the app's deployment target.
hdiutil create -quiet -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$output"

if [[ "$sign" == true ]]; then
  /usr/bin/codesign --force --timestamp --sign "$identity" "$output"
  /usr/bin/codesign --verify --strict "$output"
  echo "Signed $output with $identity"
fi

if [[ "$notarize" == true ]]; then
  result="$work_dir/result.json"
  xcrun notarytool submit "$output" --keychain-profile "$notary_profile" --wait --output-format json >"$result"
  status="$(/usr/bin/plutil -extract status raw -o - "$result")"
  submission="$(/usr/bin/plutil -extract id raw -o - "$result")"
  if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $submission ended as $status" >&2
    xcrun notarytool log "$submission" --keychain-profile "$notary_profile" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$output"
  xcrun stapler validate "$output"
  echo "Notarized $output ($submission)"
fi

echo "Created $output"
