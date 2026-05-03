#!/usr/bin/env bash
set -euo pipefail

find_first() {
  local root="$1"
  local pattern="$2"

  while IFS= read -r candidate; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(/usr/bin/find "$root" -name "$pattern" -print)

  return 1
}

if [[ -z "${TEST_SRCDIR:-}" || -z "${TEST_TMPDIR:-}" ]]; then
  echo "error: TEST_SRCDIR and TEST_TMPDIR must be set by bazel test" >&2
  exit 1
fi

test_bundle="$(find_first "$TEST_SRCDIR" "TheBrowserTestsBinary.xctest")"
resource_file="$(find_first "$TEST_SRCDIR" "public_suffix_list.dat")"

staged_bundle="$TEST_TMPDIR/TheBrowserTestsBinary.xctest"
resource_bundle="$staged_bundle/Contents/Resources/DomainParser_DomainParser.bundle"

rm -rf "$staged_bundle"
/usr/bin/ditto "$test_bundle" "$staged_bundle"

mkdir -p "$resource_bundle"
cp "$resource_file" "$resource_bundle/public_suffix_list.dat"

if [[ -z "${SDKROOT:-}" ]]; then
  export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
fi

exec "$staged_bundle/Contents/MacOS/TheBrowserTestsBinary" "$@"
