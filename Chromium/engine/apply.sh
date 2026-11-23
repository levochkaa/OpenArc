#!/usr/bin/env bash
# apply.sh <chromium src>: puts OpenArc's Chrome engine layer into a plain Chromium checkout. Safe to re-run.
#   - copies Chromium/engine/openarc to <src>/openarc (linked into Chrome's framework as //openarc:core) with
#     the app's contract header (Sources/Browser/ChromeEngine/BrowserChromeEngine.h)
#   - copies the hooks headers to chrome/browser (openarc_engine_hooks.h, openarc_permission_hooks.h) and
#     components (openarc_password_hooks.h, openarc_autofill_hooks.h)
#   - OpenArc's branding (the framework is "OpenArc Framework", its helpers "OpenArc Helper (…)")
#   - the Chromium/chromium_src files listed in overrides (OpenArc's changes to Chromium shared with CEF)
#   - OpenArc's changes to Chrome's own code (patches/series); a patch already in is left alone
set -euo pipefail

SRC="${1:?usage: apply.sh <chromium src>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[[ -f "$SRC/chrome/app/chrome_main.cc" ]] || { echo "apply.sh: not a Chromium src: $SRC" >&2; exit 1; }

# Written only when different, so a rerun rebuilds nothing.
copy_if_changed() {
  mkdir -p "$(dirname "$2")"
  cmp -s "$1" "$2" || cp "$1" "$2"
}

mkdir -p "$SRC/openarc"
for file in "$HERE/openarc/"*; do
  copy_if_changed "$file" "$SRC/openarc/$(basename "$file")"
done
copy_if_changed "$ROOT/Sources/Browser/ChromeEngine/BrowserChromeEngine.h" "$SRC/openarc/BrowserChromeEngine.h"
copy_if_changed "$HERE/hooks/openarc_engine_hooks.h" "$SRC/chrome/browser/openarc_engine_hooks.h"
copy_if_changed "$HERE/hooks/openarc_permission_hooks.h" "$SRC/chrome/browser/openarc_permission_hooks.h"
copy_if_changed "$HERE/hooks/openarc_password_hooks.h" \
  "$SRC/components/password_manager/content/browser/openarc_password_hooks.h"
copy_if_changed "$HERE/hooks/openarc_autofill_hooks.h" \
  "$SRC/components/autofill/core/browser/openarc_autofill_hooks.h"
copy_if_changed "$HERE/branding/BRANDING" "$SRC/chrome/app/theme/chromium/BRANDING"

grep -v '^#' "$HERE/overrides" | while read -r override; do
  [[ -n "$override" ]] || continue
  copy_if_changed "$ROOT/Chromium/chromium_src/$override" "$SRC/$override"
done

grep -v '^#' "$HERE/patches/series" | while read -r patch; do
  [[ -n "$patch" ]] || continue
  if git -C "$SRC" apply --reverse --check "$HERE/patches/$patch" 2>/dev/null; then
    continue
  fi
  git -C "$SRC" apply "$HERE/patches/$patch" || { echo "apply.sh: $patch doesn't apply" >&2; exit 1; }
  echo "patched $patch"
done
