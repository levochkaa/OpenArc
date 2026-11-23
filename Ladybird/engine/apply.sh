#!/usr/bin/env bash
# apply.sh <ladybird src>: puts OpenArc's Ladybird engine layer into a plain Ladybird checkout. Safe to re-run.
#   - copies Ladybird/engine/openarc to <src>/UI/OpenArc/openarc and CMakeLists.txt to <src>/UI/OpenArc, with the
#     app's contract headers (Sources/Browser/LadybirdEngine/BrowserLadybirdEngine.h and the Chrome engine's
#     BrowserChromeEngine.h it builds on) at the paths the app includes them by
#   - OpenArc's changes to Ladybird's own code (patches/series); a patch already in is left alone
set -euo pipefail

SRC="${1:?usage: apply.sh <ladybird src>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[[ -f "$SRC/Libraries/LibWebView/ViewImplementation.h" ]] || { echo "apply.sh: not a Ladybird checkout: $SRC" >&2; exit 1; }
[[ -d "$SRC/UI/AppKit" ]] || { echo "apply.sh: $SRC has no AppKit port; use the commit in LADYBIRD_COMMIT" >&2; exit 1; }

# Written only when different, so a rerun rebuilds nothing.
copy_if_changed() {
  mkdir -p "$(dirname "$2")"
  cmp -s "$1" "$2" || cp "$1" "$2"
}

LAYER="$SRC/UI/OpenArc"
mkdir -p "$LAYER/openarc"
for file in "$HERE/openarc/"*; do
  copy_if_changed "$file" "$LAYER/openarc/$(basename "$file")"
done
copy_if_changed "$HERE/CMakeLists.txt" "$LAYER/CMakeLists.txt"
copy_if_changed "$ROOT/Sources/Browser/LadybirdEngine/BrowserLadybirdEngine.h" \
  "$LAYER/Browser/LadybirdEngine/BrowserLadybirdEngine.h"
copy_if_changed "$ROOT/Sources/Browser/ChromeEngine/BrowserChromeEngine.h" \
  "$LAYER/Browser/ChromeEngine/BrowserChromeEngine.h"

grep -v '^#' "$HERE/patches/series" | while read -r patch; do
  [[ -n "$patch" ]] || continue
  if git -C "$SRC" apply --reverse --check "$HERE/patches/$patch" 2>/dev/null; then
    continue
  fi
  git -C "$SRC" apply "$HERE/patches/$patch" || { echo "apply.sh: $patch doesn't apply" >&2; exit 1; }
  echo "patched $patch"
done
