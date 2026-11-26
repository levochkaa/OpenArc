#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/sparkle_tools.sh"

usage() {
  printf 'Usage: %s --repo OWNER/REPO [--tag TAG] [--notes FILE] [--app PATH] [--prerelease] [--no-build] [--no-publish] [--no-notarize]\n' "$0" >&2
  exit 2
}

repo="${GITHUB_RELEASE_REPOSITORY:-}"
tag="${TAG:-}"
notes_file="${RELEASE_NOTES_FILE:-}"
app_bundle="${APP_BUNDLE:-}"
build_app=true
publish=true
prerelease="${PRERELEASE:-false}"
notarize=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --notes)
      notes_file="${2:-}"
      shift 2
      ;;
    --app)
      app_bundle="${2:-}"
      build_app=false
      shift 2
      ;;
    --no-build)
      build_app=false
      shift
      ;;
    --no-publish)
      publish=false
      shift
      ;;
    --prerelease)
      prerelease=true
      shift
      ;;
    --no-notarize)
      notarize=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$repo" && "$publish" == true ]]; then
  echo "error: --repo OWNER/REPO is required when publishing to GitHub" >&2
  exit 2
fi

if [[ -n "${SPARKLE_ED_KEY_FILE:-}" && -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "error: set either SPARKLE_ED_KEY_FILE or SPARKLE_ED_PRIVATE_KEY, not both" >&2
  exit 2
fi

ensure_sparkle_tools

if [[ "$build_app" == true ]]; then
  CONFIGURATION=Release "$ROOT_DIR/build.sh" build
fi

if [[ -z "$app_bundle" ]]; then
  app_bundle="$ROOT_DIR/.build/xcode/Build/Products/Release/OpenArc.app"
fi

if [[ ! -d "$app_bundle" ]]; then
  echo "error: app bundle not found at $app_bundle" >&2
  exit 1
fi

# The build stages the Chrome engine only when its Chromium matches CEF's, and otherwise goes on without it. A
# release without it moves everyone who picked Chrome's engine back to CEF, so it stops here.
if [[ ! -d "$app_bundle/Contents/Frameworks/OpenArc Framework.framework" &&
  "${OPENARC_RELEASE_WITHOUT_CHROME_ENGINE:-0}" != "1" ]]; then
  echo "error: $app_bundle has no Chrome engine; run ./script/chrome_engine.sh pull (or build, package, pull)" \
    "and build again, or set OPENARC_RELEASE_WITHOUT_CHROME_ENGINE=1 to release without it" >&2
  exit 1
fi

info_plist="$app_bundle/Contents/Info.plist"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
tag="${tag:-v$short_version-$build_version}"

release_root="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/.build/releases}"
updates_dir="${SPARKLE_UPDATES_DIR:-$release_root/sparkle-updates}"
work_dir="$release_root/work/$tag"
archive_name="OpenArc-$short_version-$build_version.zip"
archive_path="$updates_dir/$archive_name"
# generate_appcast pairs release notes by the archive's name without .zip.
generated_notes_path="$updates_dir/${archive_name%.zip}.md"
# The disk image is for first installs from the release page. It stays out of
# $updates_dir: generate_appcast would list it next to the zip.
dmg_path="$work_dir/${archive_name%.zip}.dmg"
# The server proxies downloads, so they work while the repository is private.
download_url_prefix="${OPENARC_UPDATE_DOWNLOAD_URL_PREFIX:-https://api.openarc.su/downloads/}"
# A prefix without a trailing slash loses its last path component.
download_url_prefix="${download_url_prefix%/}/"
maximum_versions="${SPARKLE_MAXIMUM_VERSIONS:-1}"
maximum_deltas="${SPARKLE_MAXIMUM_DELTAS:-5}"
sparkle_key_account="${SPARKLE_KEY_ACCOUNT:-OpenArc}"
release_title="${RELEASE_TITLE:-OpenArc $short_version ($build_version)}"
release_notes_for_github="$work_dir/release-notes.md"

rm -rf "$work_dir"
mkdir -p "$updates_dir" "$work_dir"
rm -f "$archive_path" "$generated_notes_path"

# Developer ID signing and notarization act on a copy, so the build output
# keeps its development signature.
if [[ "$notarize" == true ]]; then
  ditto "$app_bundle" "$work_dir/OpenArc.app"
  app_bundle="$work_dir/OpenArc.app"
  "$ROOT_DIR/script/sign_release_app.sh" "$app_bundle" --notarize
fi

ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path"

dmg_args=()
if [[ "$notarize" == true ]]; then
  dmg_args+=(--notarize)
fi
"$ROOT_DIR/script/make_dmg.sh" "$app_bundle" "$dmg_path" ${dmg_args[@]+"${dmg_args[@]}"}

if [[ -n "$notes_file" ]]; then
  cp "$notes_file" "$generated_notes_path"
  cp "$notes_file" "$release_notes_for_github"
else
  printf 'OpenArc %s (%s)\n' "$short_version" "$build_version" >"$generated_notes_path"
  cp "$generated_notes_path" "$release_notes_for_github"
fi

generate_appcast_args=(
  "--download-url-prefix" "$download_url_prefix"
  # GitHub serves .md assets as downloads, which Sparkle cannot show.
  "--embed-release-notes"
  "--maximum-versions" "$maximum_versions"
  "--maximum-deltas" "$maximum_deltas"
)

if [[ -n "$sparkle_key_account" ]]; then
  generate_appcast_args+=("--account" "$sparkle_key_account")
fi

if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  generate_appcast_args+=("--ed-key-file" "$SPARKLE_ED_KEY_FILE")
fi

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" \
    | "$SPARKLE_TOOLS_DIR/bin/generate_appcast" "${generate_appcast_args[@]}" --ed-key-file - "$updates_dir"
else
  "$SPARKLE_TOOLS_DIR/bin/generate_appcast" "${generate_appcast_args[@]}" "$updates_dir"
fi

appcast_path="$updates_dir/appcast.xml"
if [[ ! -f "$appcast_path" ]]; then
  echo "error: Sparkle did not generate $appcast_path" >&2
  exit 1
fi

# macOS ships bash 3.2, which has no mapfile.
assets=("$archive_path" "$dmg_path" "$generated_notes_path" "$appcast_path")
while IFS= read -r delta_asset; do
  assets+=("$delta_asset")
done < <(find "$updates_dir" -maxdepth 1 -type f -name '*.delta' -print)

if [[ "$publish" == true ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: GitHub CLI 'gh' is required for publishing" >&2
    exit 1
  fi

  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$tag" "${assets[@]}" --repo "$repo" --clobber
    if [[ "$prerelease" == true ]]; then
      gh release edit "$tag" --repo "$repo" --prerelease
    fi
  else
    release_create_args=("$tag" "${assets[@]}" --repo "$repo" --title "$release_title" --notes-file "$release_notes_for_github")
    if [[ "$prerelease" == true ]]; then
      release_create_args+=(--prerelease)
    fi

    gh release create "${release_create_args[@]}"
  fi
fi

printf 'Archive: %s\n' "$archive_path"
printf 'Disk image: %s\n' "$dmg_path"
printf 'Appcast: %s\n' "$appcast_path"
printf 'Tag: %s\n' "$tag"
