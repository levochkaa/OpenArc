#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./script/run_ios_simulator.sh iphone|ipad [--skip-build]"
  echo "Builds the iOS app and launches it on a dedicated OpenArc simulator."
  echo "A missing device is created on the newest installed iOS runtime that supports it."
}

case "${1:-}" in
  iphone)
    device_name="OpenArc iPhone"
    device_type="iPhone 17 Pro"
    ;;
  ipad)
    device_name="OpenArc iPad"
    device_type="iPad Air 11-inch (M4)"
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
skip_build=false
if [[ "${2:-}" == "--skip-build" ]]; then
  skip_build=true
elif [[ -n "${2:-}" ]]; then
  usage >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/script/xcode_env.sh"
configuration="${CONFIGURATION:-Debug}"
app="$repo_root/.build/xcode-ios/Build/Products/$configuration-iphonesimulator/OpenArc.app"

if [[ "$skip_build" == false ]]; then
  "$repo_root/build.sh" ios-build --configuration "$configuration"
fi
if [[ ! -d "$app" ]]; then
  echo "error: $app is missing; run without --skip-build" >&2
  exit 1
fi

udid="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"].values()
print(next((d["udid"] for runtime in devices for d in runtime if d["name"] == name), ""))
' "$device_name")"
if [[ -z "$udid" ]]; then
  runtime="$(xcrun simctl list runtimes available -j | python3 -I -c '
import json, sys
device_type = sys.argv[1]
runtimes = [
    r for r in json.load(sys.stdin)["runtimes"]
    if r["platform"] == "iOS" and any(t["name"] == device_type for t in r.get("supportedDeviceTypes", []))
]
version = lambda r: tuple(int(part) for part in r["version"].split("."))
print(max(runtimes, key=version)["identifier"] if runtimes else "")
' "$device_type")"
  if [[ -z "$runtime" ]]; then
    echo "error: no installed iOS runtime supports $device_type" >&2
    exit 1
  fi
  echo "Creating $device_name ($device_type, $runtime)"
  udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl boot "$udid" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" "$bundle_id"
echo "Launched $bundle_id on $device_name ($udid)"
