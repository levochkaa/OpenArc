#!/usr/bin/env bash
# Builds OpenArc's Chrome engine (Chrome's framework with Chromium/engine) for
# macOS arm64 on a Linux x64 host.
#
# Runs on the Linux build host. script/chrome_engine.sh on the Mac copies this
# directory, Chromium/engine and the engine's contract header to the host and
# calls these commands; see docs/chrome-engine.md.
#
# Layout under CHROME_ENGINE_ROOT (default: two levels above this script):
#   chromium/src/    plain Chromium: a copy of the CEF build root's checkout
#                    without src/cef and src/out, CEF's and OpenArc's CEF
#                    changes reverted; out/OpenArc_arm64 is the engine's out dir
#   openarc/tools/   this directory
#   openarc/repo/    Chromium/engine and Sources/Browser/ChromeEngine/
#                    BrowserChromeEngine.h at their repository paths
#   artifacts/dist/  the last OpenArc Framework.framework
#
# The CEF build root (CEF_CROSS_ROOT) gives the checkout to copy, depot_tools
# and the hermetic Xcode, so the engine builds from the same Chromium tag as
# the exported CEF.
set -euo pipefail

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CHROME_ENGINE_ROOT:-$(cd "$TOOLS_DIR/../.." && pwd)}"
CEF_ROOT="${CEF_CROSS_ROOT:-}"
SRC="$ROOT/chromium/src"
REPO="$ROOT/openarc/repo"
ARTIFACTS="$ROOT/artifacts"
OUT="out/OpenArc_arm64"
FRAMEWORK="OpenArc Framework.framework"
BASE_MARKER="$SRC/.openarc-engine-base"
CHROMIUM_TAG="${CHROMIUM_TAG:-}"

step() { echo; echo "=== $(date '+%F %T') $*"; }
die() { echo "=== $(date '+%F %T') FAILED: $*" >&2; exit 1; }

[[ -n "$CEF_ROOT" ]] || die "set CEF_CROSS_ROOT to the CEF build root"
export PATH="$CEF_ROOT/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0

# The Chromium tag of the CEF build root's checkout, from its .gclient.
cef_checkout_tag() {
  sed -n "s/.*src\.git@\([^']*\)'.*/\1/p" "$CEF_ROOT/chromium/.gclient" | head -n 1
}

# Every git repository of the tree: src and the dependencies DEPS checks out.
tree_repositories() {
  find "$SRC" -path "$SRC/out" -prune -o -name .git -print | sed 's|/\.git$||' | sort
}

# Undoes CEF's patches, OpenArc's CEF overrides and the CEF cross-build fixes
# in every repository of the tree. Ignored files (hook downloads, toolchains)
# and nested repositories stay.
revert_tree() {
  local repo reverted=0
  while IFS= read -r repo; do
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
      git -C "$repo" checkout -q -- .
      git -C "$repo" clean -fdq
      echo "reverted ${repo#"$ROOT/chromium/"}"
      reverted=$((reverted + 1))
    fi
  done < <(tree_repositories)
  echo "reverted $reverted repositories"
}

# A plain Chromium tree at CHROMIUM_TAG, copied from the CEF build root. Runs
# again only when the tag changes, so a later prepare keeps the build cache.
copy_tree() {
  [[ -n "$CHROMIUM_TAG" ]] || die "set CHROMIUM_TAG"
  if [[ -f "$BASE_MARKER" && "$(cat "$BASE_MARKER")" == "$CHROMIUM_TAG" ]]; then
    echo "the engine tree is at Chromium $CHROMIUM_TAG"
    return
  fi
  local cef_tag
  cef_tag="$(cef_checkout_tag)"
  [[ "$cef_tag" == "$CHROMIUM_TAG" ]] ||
    die "the CEF build root's checkout is at Chromium ${cef_tag:-?}, the engine needs $CHROMIUM_TAG; run script/cef_remote_build.sh fetch"
  step "copy Chromium $CHROMIUM_TAG from $CEF_ROOT/chromium"
  mkdir -p "$ROOT/chromium"
  # The engine's out dir is excluded, so --delete keeps it.
  rsync -a --delete --exclude /src/out/ --exclude /src/cef/ "$CEF_ROOT/chromium/" "$ROOT/chromium/"
  step "revert CEF's changes"
  revert_tree
  printf '%s\n' "$CHROMIUM_TAG" > "$BASE_MARKER"
}

link_xcode() {
  local xcode="$CEF_ROOT/xcode_binaries"
  [[ -f "$xcode/Contents/version.plist" ]] ||
    die "no hermetic Xcode at $xcode; run script/cef_remote_build.sh xcode on the Mac"
  mkdir -p "$SRC/build/mac_files"
  ln -sfn "$xcode" "$SRC/build/mac_files/xcode_binaries"
}

apply_layer() {
  [[ -f "$BASE_MARKER" ]] || die "no engine tree at $SRC; run prepare"
  step "OpenArc's engine layer"
  bash "$REPO/Chromium/engine/apply.sh" "$SRC"
}

# The CEF build's runtime shape (official, PGO, ThinLTO, Chrome's codecs),
# cross-compiled against the hermetic SDK.
gen() {
  local args="$SRC/$OUT/args.gn"
  local wanted
  wanted="$(cat <<EOF
target_os = "mac"
target_cpu = "arm64"
use_system_xcode = false
is_official_build = true
is_debug = false
is_component_build = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
enable_dsyms = false
dcheck_always_on = false
enable_expensive_dchecks = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"
enable_widevine = true
disable_fieldtrial_testing_config = true
clang_use_chrome_plugins = false
enable_precompiled_headers = false
enable_resource_allowlist_generation = false
${EXTRA_GN_ARGS:-}
EOF
)"
  mkdir -p "$SRC/$OUT"
  # Rewritten only when different: a new args.gn reruns gn for the whole tree.
  if [[ ! -f "$args" || "$(cat "$args")" != "$wanted" ]]; then
    printf '%s\n' "$wanted" > "$args"
  fi
  step "gn gen $OUT"
  (cd "$SRC" && gn gen "$OUT")
  (cd "$SRC" && gn args "$OUT" --list --short) |
    grep -E '^(target_os|target_cpu|host_os|use_system_xcode|is_official_build|use_thin_lto|chrome_pgo_phase|proprietary_codecs|use_lld) =' || true
}

prepare() {
  copy_tree
  link_xcode
  step "cross-build fixes"
  python3 "$TOOLS_DIR/crossfix.py" "$SRC"
  apply_layer
  gen
  echo "prepare exit 0"
}

build() {
  [[ -f "$SRC/$OUT/args.gn" ]] || die "no $OUT; run prepare"
  apply_layer
  step "build chrome_framework"
  # -k 0 builds everything it can past a failure, so a layer error shows up at
  # the end of a first build together with the rest, and the next run only
  # rebuilds what failed.
  # The build yields the host to everything else: idle CPU and disk priority,
  # and NINJA_JOBS, when set, caps the jobs autoninja would run.
  local idle=(nice -n 19) jobs=()
  command -v ionice >/dev/null && idle=(ionice -c3 nice -n 19)
  [[ -n "${NINJA_JOBS:-}" ]] && jobs=(-j "$NINJA_JOBS")
  (cd "$SRC" && "${idle[@]}" autoninja -C "$OUT" -k 0 "${jobs[@]}" chrome_framework) || die "build"
  echo "build exit 0"
}

package() {
  local framework="$SRC/$OUT/$FRAMEWORK"
  [[ -d "$framework" ]] || die "no built framework at $framework"
  step "package $FRAMEWORK"
  rm -rf "$ARTIFACTS/dist"
  mkdir -p "$ARTIFACTS/dist"
  # The framework's own Versions links stay; links out of it are copied.
  rsync -a --copy-unsafe-links "$framework" "$ARTIFACTS/dist/"
  printf '%s\n' "$CHROMIUM_TAG" > "$ARTIFACTS/dist/.chromium-version"
  du -sh "$ARTIFACTS/dist/$FRAMEWORK"
  echo "package exit 0"
}

case "$COMMAND" in
  prepare) prepare ;;
  apply) apply_layer ;;
  gen) gen ;;
  build) build ;;
  package) package ;;
  all) prepare; build; package ;;
  help|-h|--help)
    sed -n '2,20p' "$0"
    echo
    echo "Commands: prepare | apply | gen | build | package | all"
    ;;
  *) die "unknown command $COMMAND" ;;
esac
