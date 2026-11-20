#!/usr/bin/env bash
# Builds OpenArc's arm64 macOS CEF framework on a Linux x64 host.
#
# Runs on the Linux build host. script/cef_remote_build.sh on the Mac copies this
# directory and Chromium/chromium_src to the host and calls these commands; see
# docs/cef-build.md.
#
# Layout under CEF_CROSS_ROOT (default: two levels above this script):
#   depot_tools/      Chromium's depot_tools
#   cef/              CEF checkout (the branch and commit to build)
#   chromium/src/     Chromium checkout; the CEF tree is copied into src/cef
#   xcode_binaries/   hermetic Xcode: macOS SDK and version.plist from the Mac
#   openarc/tools/    this directory
#   openarc/chromium_src/  OpenArc's Chromium/chromium_src overrides
#   artifacts/        framework tar and the binary distribution
set -euo pipefail

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CEF_CROSS_ROOT:-$(cd "$TOOLS_DIR/../.." && pwd)}"
DEPOT_TOOLS="$ROOT/depot_tools"
CEF_CHECKOUT_DIR="$ROOT/cef"
CHROMIUM_ROOT="$ROOT/chromium"
SRC="$CHROMIUM_ROOT/src"
CEF_SRC="$SRC/cef"
XCODE_DIR="$ROOT/xcode_binaries"
# chromium_watch.py points this at a merged set while it moves the base.
OVERRIDES="${OPENARC_OVERRIDES_DIR:-$ROOT/openarc/chromium_src}"
ARTIFACTS="$ROOT/artifacts"
OUT_CONFIG="Release_GN_arm64"
OUT="out/$OUT_CONFIG"

# What to build. script/cef_remote_build.sh passes the baseline from
# ThirdParty/cef/export/include/cef_version.h.
CEF_BRANCH="${CEF_BRANCH:-}"
CEF_COMMIT="${CEF_COMMIT:-}"
CHROMIUM_TAG="${CHROMIUM_TAG:-}"
DEPOT_TOOLS_REF="${DEPOT_TOOLS_REF:-}"
# chromium.googlesource.com answers 429 (anonymous short-term quota) when many
# DEPS repositories fetch at once; fewer jobs and a retry with a pause get past it.
GCLIENT_JOBS="${GCLIENT_JOBS:-8}"
GCLIENT_ATTEMPTS="${GCLIENT_ATTEMPTS:-6}"

# The Mac build's runtime shape (see DEFAULT_CHROMIUM_GN_DEFINES in
# script/chromium_source.sh), cross-compiled against the hermetic SDK.
GN_DEFINES_DEFAULT="blink_symbol_level=0 dcheck_always_on=false enable_dsyms=false enable_expensive_dchecks=false ffmpeg_branding=Chrome forbid_non_component_debug_builds=false is_component_build=false is_official_build=true proprietary_codecs=true symbol_level=0 v8_symbol_level=0 target_os=mac use_system_xcode=false"

export PATH="$DEPOT_TOOLS:$PATH" DEPOT_TOOLS_UPDATE=0

step() { echo; echo "=== $(date '+%F %T') $*"; }
die() { echo "=== $(date '+%F %T') FAILED: $*" >&2; exit 1; }

require_versions() {
  [[ -n "$CEF_BRANCH" && -n "$CEF_COMMIT" && -n "$CHROMIUM_TAG" ]] ||
    die "set CEF_BRANCH, CEF_COMMIT and CHROMIUM_TAG"
}

ensure_depot_tools() {
  if [[ ! -d "$DEPOT_TOOLS/.git" ]]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
  fi
  if [[ -n "$DEPOT_TOOLS_REF" ]]; then
    git -C "$DEPOT_TOOLS" fetch -q origin
    git -C "$DEPOT_TOOLS" checkout -q "$DEPOT_TOOLS_REF"
  fi
  (cd "$DEPOT_TOOLS" && ./ensure_bootstrap >/dev/null)
}

# gclient sync resumes where it stopped, so a failed run is retried with a
# growing pause (1, 2, 4, 8, 15 min) and half the jobs each time, down to 2.
gclient_sync() {
  local attempt=1 jobs="$GCLIENT_JOBS" pause=60
  until (cd "$CHROMIUM_ROOT" && gclient sync --reset --nohooks --no-history --jobs="$jobs"); do
    ((attempt < GCLIENT_ATTEMPTS)) || die "gclient sync failed $attempt times"
    echo "=== $(date '+%F %T') gclient sync failed (attempt $attempt of $GCLIENT_ATTEMPTS); retrying in ${pause}s"
    sleep "$pause"
    attempt=$((attempt + 1))
    jobs=$((jobs > 3 ? jobs / 2 : 2))
    pause=$((pause * 2 > 900 ? 900 : pause * 2))
  done
}

# CEF and Chromium sources at the requested versions, with macOS dependencies.
fetch() {
  require_versions
  mkdir -p "$ROOT"
  step "depot_tools"
  ensure_depot_tools

  step "CEF $CEF_BRANCH at $CEF_COMMIT"
  if [[ ! -d "$CEF_CHECKOUT_DIR/.git" ]]; then
    git clone --branch "$CEF_BRANCH" https://github.com/chromiumembedded/cef.git "$CEF_CHECKOUT_DIR"
  fi
  git -C "$CEF_CHECKOUT_DIR" fetch -q origin "$CEF_BRANCH"
  git -C "$CEF_CHECKOUT_DIR" checkout -q --force "$CEF_COMMIT"
  git -C "$CEF_CHECKOUT_DIR" log -1 --oneline

  step "Chromium $CHROMIUM_TAG"
  mkdir -p "$CHROMIUM_ROOT"
  cat > "$CHROMIUM_ROOT/.gclient" <<GCLIENT
solutions = [{'managed': False, 'name': 'src', 'url': 'https://chromium.googlesource.com/chromium/src.git@$CHROMIUM_TAG', 'custom_vars': {'checkout_pgo_profiles': True, 'source_tarball': False, 'siso_version': 'latest', }, 'custom_deps': {}, 'deps_file': 'DEPS', 'safesync_url': ''}]
target_os = ['mac']
GCLIENT
  if [[ -d "$SRC/.git" ]]; then
    # A moved base: drop the previous CEF copy and local edits first.
    rm -rf "$CEF_SRC"
    git -C "$SRC" reset -q --hard
    git -C "$SRC" fetch -q origin "refs/tags/$CHROMIUM_TAG" --no-tags --depth=1
    git -C "$SRC" checkout -q --force FETCH_HEAD
  fi
  gclient_sync
  if [[ -f "$CEF_CHECKOUT_DIR/patch/patches/runhooks.patch" ]]; then
    python3 "$CEF_CHECKOUT_DIR/tools/patcher.py" \
      --patch-file "$CEF_CHECKOUT_DIR/patch/patches/runhooks" \
      --patch-dir "$SRC" || echo "warning: runhooks.patch did not apply"
  fi
  (cd "$CHROMIUM_ROOT" && gclient runhooks)
  echo "fetch exit 0"
}

require_xcode() {
  [[ -f "$XCODE_DIR/Contents/version.plist" ]] ||
    die "no hermetic Xcode at $XCODE_DIR; run script/cef_remote_build.sh xcode on the Mac"
  ls -d "$XCODE_DIR"/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk >/dev/null 2>&1 ||
    die "no MacOSX.sdk in $XCODE_DIR"
}

# Copies CEF into src/cef with OpenArc's CEF patch overrides, applies the
# cross-build fixes, then runs CEF's hook (version headers, patches, gn gen)
# as if on an arm64 Mac.
prepare() {
  [[ -d "$SRC/.git" ]] || die "no Chromium checkout at $SRC; run fetch"
  require_xcode
  mkdir -p "$SRC/build/mac_files"
  ln -sfn "$XCODE_DIR" "$SRC/build/mac_files/xcode_binaries"

  step "copy CEF into src/cef"
  rsync -a --delete --exclude binary_distrib "$CEF_CHECKOUT_DIR/" "$CEF_SRC/"
  if [[ -d "$OVERRIDES/cef/patch" ]]; then
    rsync -a "$OVERRIDES/cef/patch/" "$CEF_SRC/patch/"
    echo "applied CEF patch overrides"
  fi

  step "cross-build fixes"
  python3 "$TOOLS_DIR/crossfix.py" "$SRC"

  step "CEF hook and gn gen"
  local gn_defines="$GN_DEFINES_DEFAULT ${EXTRA_GN_DEFINES:-}"
  GN_DEFINES="$gn_defines" GN_OUT_CONFIGS="$OUT_CONFIG" \
    python3 "$TOOLS_DIR/run_as_mac.py" "$CEF_SRC" gclient_hook.py
  print_gn_args
}

print_gn_args() {
  (cd "$SRC" && gn args "$OUT" --list --short) | grep -E '^(target_os|target_cpu|host_os|use_system_xcode|is_official_build|use_thin_lto|chrome_pgo_phase|proprietary_codecs|ffmpeg_branding|use_lld|is_component_build|dcheck_always_on) =' || true
}

# OpenArc's full-file overrides, copied over the CEF-patched tree.
apply_overrides() {
  [[ -d "$CEF_SRC" ]] || die "no CEF tree at $CEF_SRC; run prepare"
  [[ -d "$OVERRIDES" ]] || die "no overrides at $OVERRIDES"
  local file relative
  while IFS= read -r file; do
    relative="${file#"$OVERRIDES"/}"
    mkdir -p "$(dirname "$SRC/$relative")"
    if ! cmp -s "$file" "$SRC/$relative"; then
      cp "$file" "$SRC/$relative"
      echo "applied $relative"
    fi
  done < <(find "$OVERRIDES" -type f ! -name .gitkeep | sort)
}

build() {
  [[ -f "$SRC/$OUT/args.gn" ]] || die "no $OUT; run prepare"
  step "build cef_framework"
  # Idle CPU and disk priority, so the host stays usable for other work.
  local idle=(nice -n 19)
  command -v ionice >/dev/null && idle=(ionice -c3 nice -n 19)
  (cd "$SRC" && "${idle[@]}" autoninja -C "$OUT" cef_framework) || die "build"
}

# A minimal binary distribution: include/, libcef_dll/, cmake/, CMakeLists.txt,
# CREDITS.html and Release/Chromium Embedded Framework.framework. The sample
# apps need ibtool, which Linux lacks, so make_distrib takes the framework
# from a stand-in cefclient.app.
package() {
  local framework="$SRC/$OUT/Chromium Embedded Framework.framework"
  [[ -d "$framework" ]] || die "no built framework at $framework"
  local stand_in="$SRC/$OUT/cefclient.app/Contents/Frameworks"
  mkdir -p "$stand_in"
  ln -sfn "../../../Chromium Embedded Framework.framework" "$stand_in/Chromium Embedded Framework.framework"

  step "make_distrib"
  rm -rf "$CEF_SRC/binary_distrib"
  python3 "$TOOLS_DIR/run_as_mac.py" "$CEF_SRC" make_distrib.py \
    --output-dir ../binary_distrib --ninja-build --arm64-build --no-symbols \
    --no-docs --no-archive --minimal --allow-partial || die "make_distrib"

  local dist
  dist="$(ls -d "$CEF_SRC"/binary_distrib/cef_binary_*_macosarm64_minimal | head -1)"
  [[ -d "$dist/Release/Chromium Embedded Framework.framework" ]] || die "no framework in $dist"
  rm -rf "$ARTIFACTS/dist"
  mkdir -p "$ARTIFACTS"
  # The distribution may link into the out dir; copy what those links point
  # to, and keep the framework's own Versions links.
  rsync -a --copy-unsafe-links "$dist/" "$ARTIFACTS/dist/"
  basename "$dist" > "$ARTIFACTS/dist/.distribution-name"
  grep '^#define CEF_VERSION ' "$ARTIFACTS/dist/include/cef_version.h"
  du -sh "$ARTIFACTS/dist"
  echo "package exit 0"
}

all() {
  prepare
  apply_overrides
  build
  package
  echo "build exit 0"
}

case "$COMMAND" in
  fetch) fetch ;;
  prepare) prepare ;;
  apply-overrides) apply_overrides ;;
  build) apply_overrides; build ;;
  package) package ;;
  all) all ;;
  gn-args) print_gn_args ;;
  help|-h|--help)
    sed -n '2,16p' "$0"
    echo
    echo "Commands: fetch | prepare | apply-overrides | build | package | all | gn-args"
    ;;
  *) die "unknown command $COMMAND" ;;
esac
