#!/usr/bin/env bash
set -euo pipefail

# Archives the iOS app, uploads it to App Store Connect and gives it to an
# internal TestFlight group. See docs/ios-testflight.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/OpenArc.xcodeproj"
SCHEME="OpenArciOS"
CONFIGURATION="Release"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-ios-release"
OUTPUT_ROOT="$ROOT_DIR/.build/ios-testflight"

build_number=""
group_name="${OPENARC_TESTFLIGHT_GROUP:-Internal}"
testers=()
add_admins=1
upload=1
wait_for_processing=1

usage() {
  cat <<'EOF'
Usage: ./script/ios_testflight.sh [options]

Archives OpenArciOS in Release, uploads it to App Store Connect, waits for
processing and adds the build to an internal TestFlight group.

Options:
  --build-number N   Use this build number instead of the next free one on App Store Connect.
  --group NAME       Internal TestFlight group (default: $OPENARC_TESTFLIGHT_GROUP or Internal).
  --tester EMAIL     Add this App Store Connect user to the group. Repeatable.
  --no-admins        Do not add the team's Account Holder and Admins to the group.
  --archive-only     Archive and export an .ipa without uploading.
  --no-wait          Upload and stop, without waiting for processing.
  -h, --help         Show this help.

Environment:
  OPENARC_ASC_KEY_ID, OPENARC_ASC_ISSUER_ID, OPENARC_ASC_KEY_PATH
                     App Store Connect API key (Admin or App Manager role).
  DEVELOPMENT_TEAM   Signing team. Defaults to the team that owns the bundle ID.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      [[ $# -ge 2 ]] || { echo "error: --build-number requires a value" >&2; exit 2; }
      build_number="$2"
      shift 2
      ;;
    --group)
      [[ $# -ge 2 ]] || { echo "error: --group requires a value" >&2; exit 2; }
      group_name="$2"
      shift 2
      ;;
    --tester)
      [[ $# -ge 2 ]] || { echo "error: --tester requires a value" >&2; exit 2; }
      testers+=("$2")
      shift 2
      ;;
    --no-admins)
      add_admins=0
      shift
      ;;
    --archive-only)
      upload=0
      shift
      ;;
    --no-wait)
      wait_for_processing=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for name in OPENARC_ASC_KEY_ID OPENARC_ASC_ISSUER_ID OPENARC_ASC_KEY_PATH; do
  if [[ -z "${!name:-}" ]]; then
    echo "error: $name is not set" >&2
    exit 2
  fi
done
if [[ ! -f "$OPENARC_ASC_KEY_PATH" ]]; then
  echo "error: OPENARC_ASC_KEY_PATH does not point to a file" >&2
  exit 2
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "error: --build-number must be a positive integer" >&2
  exit 2
fi

asc() {
  python3 -I "$ROOT_DIR/script/asc_api.py" "$@"
}

# Runs xcodebuild with its output in a log, printing the tail on failure.
run_logged() {
  local log="$1"
  shift
  if ! "$@" >"$log" 2>&1; then
    grep -E 'error:|warning:|\*\* .* FAILED' "$log" | tail -40 >&2 || true
    tail -20 "$log" >&2
    echo "error: failed, full log: $log" >&2
    exit 1
  fi
}

build_setting() {
  awk -v key="$1" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }' <<<"$build_settings"
}

source "$ROOT_DIR/script/xcode_env.sh"
"$ROOT_DIR/script/generate_xcodeproj.sh" >/dev/null
source_packages_dir="$("$ROOT_DIR/script/package_graph_cache.sh" path)"
"$ROOT_DIR/script/package_graph_cache.sh" prepare "$SCHEME" "$DERIVED_DATA_PATH" >/dev/null

package_args=(
  -clonedSourcePackagesDirPath "$source_packages_dir"
  -disableAutomaticPackageResolution
  -packageAuthorizationProvider netrc
  -scmProvider system
  -skipPackagePluginValidation
  -skipMacroValidation
)
auth_args=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$OPENARC_ASC_KEY_PATH"
  -authenticationKeyID "$OPENARC_ASC_KEY_ID"
  -authenticationKeyIssuerID "$OPENARC_ASC_ISSUER_ID"
)

build_settings="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" "${package_args[@]}" -showBuildSettings 2>/dev/null)"
bundle_id="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
marketing_version="$(build_setting MARKETING_VERSION)"
project_build_number="$(build_setting CURRENT_PROJECT_VERSION)"
[[ -n "$bundle_id" && -n "$marketing_version" ]] || { echo "error: could not read build settings" >&2; exit 1; }

team_id="${DEVELOPMENT_TEAM:-$(asc team-id "$bundle_id")}"
app_id="$(asc app-id "$bundle_id")"
if [[ -z "$build_number" ]]; then
  build_number="$(asc next-build-number "$bundle_id" --minimum "${project_build_number:-1}")"
fi
echo "OpenArc iOS $marketing_version ($build_number), $bundle_id, app $app_id"

run_dir="$OUTPUT_ROOT/$marketing_version-$build_number"
archive_path="$run_dir/OpenArc.xcarchive"
export_path="$run_dir/export"
rm -rf "$run_dir"
mkdir -p "$run_dir"

echo "Archiving $SCHEME ($CONFIGURATION)"
run_logged "$run_dir/archive.log" xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$archive_path" \
  "${package_args[@]}" \
  "${auth_args[@]}" \
  CODE_SIGN_STYLE=Automatic \
  "DEVELOPMENT_TEAM=$team_id" \
  "CURRENT_PROJECT_VERSION=$build_number" \
  archive

destination="export"
[[ "$upload" -eq 0 ]] || destination="upload"
export_options="$run_dir/ExportOptions.plist"
cat >"$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$destination</string>
  <key>teamID</key>
  <string>$team_id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

if [[ "$upload" -eq 1 ]]; then
  echo "Exporting and uploading to App Store Connect"
else
  echo "Exporting the .ipa"
fi
# The export packs the .ipa with /usr/bin/rsync, which starts the `rsync` found on PATH
# as its other end; a Homebrew rsync there rejects its options. Keep PATH to the system.
run_logged "$run_dir/export.log" env PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  "${auth_args[@]}"

if [[ "$upload" -eq 0 ]]; then
  echo "Exported $export_path"
  exit 0
fi
echo "Uploaded OpenArc iOS $marketing_version ($build_number)"

group_args=("$bundle_id" "$group_name")
[[ "$add_admins" -eq 0 ]] || group_args+=(--all-admins)
for tester in ${testers[@]+"${testers[@]}"}; do
  group_args+=(--tester "$tester")
done
asc ensure-group "${group_args[@]}" >/dev/null

if [[ "$wait_for_processing" -eq 0 ]]; then
  echo "Not waiting for processing. Add the build to $group_name once App Store Connect finishes it."
  exit 0
fi

echo "Waiting for App Store Connect to process the build"
build_id="$(asc wait-build "$bundle_id" "$marketing_version" "$build_number")"
asc add-build-to-group "$bundle_id" "$group_name" "$build_id"
asc build-status "$bundle_id" "$marketing_version" "$build_number"
