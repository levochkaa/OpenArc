#!/usr/bin/env bash
# Builds OpenArc's Chrome engine (Chrome's own framework with Chromium/engine)
# on the Linux build host and brings it to this Mac. See docs/chrome-engine.md.
set -euo pipefail

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_HOST="${OPENARC_CEF_REMOTE_HOST:-wsl}"
# Relative paths are taken from the remote home directory.
REMOTE_ROOT="${OPENARC_CHROME_ENGINE_REMOTE_ROOT:-chrome-engine}"
# The CEF build root (script/cef_remote_build.sh): its Chromium checkout,
# depot_tools and hermetic Xcode.
CEF_REMOTE_ROOT="${OPENARC_CEF_REMOTE_ROOT:-cef-mac}"
TMUX_SESSION="${OPENARC_CHROME_ENGINE_REMOTE_SESSION:-openarc-chrome-engine}"
# strip -x for the pulled framework, the Xcode CEF builds against.
CEF_XCODE="${OPENARC_CEF_XCODE:-/Applications/Xcode-26.6.0.app}"
FRAMEWORK="OpenArc Framework.framework"

primary_checkout_root() {
  local common
  common="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}

PRIMARY_ROOT="$(primary_checkout_root)"
CEF_HEADER="$PRIMARY_ROOT/ThirdParty/cef/export/include/cef_version.h"
# The app build stages the framework from here (script/stage_cef_bundle.sh).
EXPORT_DIR="$PRIMARY_ROOT/ThirdParty/chrome-engine/export"

remote_path_expr() {
  if [[ "$1" == /* ]]; then
    printf '%s' "$1"
  else
    printf '$HOME/%s' "$1"
  fi
}

remote() {
  ssh "$REMOTE_HOST" "$@"
}

define_from_header() {
  sed -n "s/^#define $1 \"\{0,1\}\([^\" ]*\)\"\{0,1\}.*/\1/p" "$2" | head -n 1
}

# The exported CEF's Chromium version: both engines open one profile, so the
# engine never moves past it. CHROMIUM_TAG overrides it.
cef_chromium_version() {
  [[ -f "$CEF_HEADER" ]] || { echo "error: no $CEF_HEADER" >&2; exit 1; }
  printf '%s.%s.%s.%s\n' \
    "$(define_from_header CHROME_VERSION_MAJOR "$CEF_HEADER")" \
    "$(define_from_header CHROME_VERSION_MINOR "$CEF_HEADER")" \
    "$(define_from_header CHROME_VERSION_BUILD "$CEF_HEADER")" \
    "$(define_from_header CHROME_VERSION_PATCH "$CEF_HEADER")"
}

resolve_version() {
  CHROMIUM_TAG="${CHROMIUM_TAG:-$(cef_chromium_version)}"
  echo "Chrome engine at Chromium $CHROMIUM_TAG"
}

# The host tools, the layer, the overrides and the contract header apply.sh
# copies, at their repository paths so apply.sh runs unchanged.
push_tools() {
  local root
  root="$(remote_path_expr "$REMOTE_ROOT")"
  remote "mkdir -p \"$root/openarc/repo/Chromium\" \"$root/openarc/repo/Sources/Browser/ChromeEngine\""
  rsync -a --delete "$ROOT_DIR/script/cef_cross/" "$REMOTE_HOST:$REMOTE_ROOT/openarc/tools/"
  rsync -a --delete "$ROOT_DIR/Chromium/engine/" "$REMOTE_HOST:$REMOTE_ROOT/openarc/repo/Chromium/engine/"
  rsync -a --delete --exclude .gitkeep "$ROOT_DIR/Chromium/chromium_src/" \
    "$REMOTE_HOST:$REMOTE_ROOT/openarc/repo/Chromium/chromium_src/"
  rsync -a "$ROOT_DIR/Sources/Browser/ChromeEngine/BrowserChromeEngine.h" \
    "$REMOTE_HOST:$REMOTE_ROOT/openarc/repo/Sources/Browser/ChromeEngine/"
  echo "Pushed script/cef_cross, Chromium/engine and Chromium/chromium_src to $REMOTE_HOST:$REMOTE_ROOT/openarc"
}

# Runs a chrome_engine_cross.sh command in a detached tmux session on the
# host, so a dropped connection does not stop a build. The log ends with
# "exit <status>".
run_remote() {
  local command="$1"
  local root cef_root
  root="$(remote_path_expr "$REMOTE_ROOT")"
  cef_root="$(remote_path_expr "$CEF_REMOTE_ROOT")"
  local env="CHROME_ENGINE_ROOT=\"$root\" CEF_CROSS_ROOT=\"$cef_root\" CHROMIUM_TAG=$CHROMIUM_TAG"
  [[ -n "${EXTRA_GN_ARGS:-}" ]] && env="$env EXTRA_GN_ARGS='$EXTRA_GN_ARGS'"
  local log="$root/logs/$command.log"
  if remote "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
    echo "error: tmux session $TMUX_SESSION is still running on $REMOTE_HOST; see $0 status" >&2
    exit 1
  fi
  remote "mkdir -p \"$root/logs\" && ln -sfn \"$command.log\" \"$root/logs/latest.log\" && tmux new-session -d -s $TMUX_SESSION \"$env bash \\\"$root/openarc/tools/chrome_engine_cross.sh\\\" $command > \\\"$log\\\" 2>&1; echo exit \\\$? >> \\\"$log\\\"\""
  echo "Started '$command' on $REMOTE_HOST (tmux $TMUX_SESSION), log $REMOTE_ROOT/logs/$command.log"
  if [[ "${WAIT:-0}" == "1" ]]; then
    wait_remote
  else
    echo "Follow with $0 status, or wait with $0 wait"
  fi
}

status_remote() {
  remote "tail -n ${LINES_SHOWN:-5} \"$(remote_path_expr "$REMOTE_ROOT")/logs/latest.log\""
}

wait_remote() {
  local last
  while true; do
    last="$(remote "tail -n 1 \"$(remote_path_expr "$REMOTE_ROOT")/logs/latest.log\"")"
    case "$last" in
      "exit 0") echo "Remote command finished"; return 0 ;;
      exit\ *) LINES_SHOWN=30 status_remote; echo "error: remote command failed ($last)" >&2; return 1 ;;
    esac
    sleep 60
  done
}

# Local symbols off every Mach-O file of the framework, as for CEF.
strip_framework() {
  local file
  while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q '^Mach-O'; then
      xcrun strip -x "$file"
    fi
  done < <(find "$1" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
}

# Copies the host's framework into ThirdParty/chrome-engine/export in the
# primary checkout. It must match the exported CEF's Chromium version.
pull() {
  local tmp="$PRIMARY_ROOT/ThirdParty/chrome-engine/.export-pull.tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  rsync -a "$REMOTE_HOST:$REMOTE_ROOT/artifacts/dist/" "$tmp/"
  [[ -d "$tmp/$FRAMEWORK" ]] || { echo "error: the host has no packaged $FRAMEWORK" >&2; exit 1; }
  local built cef
  built="$(cat "$tmp/.chromium-version" 2>/dev/null || true)"
  cef="$(cef_chromium_version)"
  if [[ "$built" != "$cef" ]]; then
    echo "error: the engine is Chromium ${built:-?}, the exported CEF is $cef; both must open one profile" >&2
    exit 1
  fi
  DEVELOPER_DIR="$CEF_XCODE/Contents/Developer" strip_framework "$tmp/$FRAMEWORK"
  mkdir -p "$EXPORT_DIR"
  rm -rf "$EXPORT_DIR/$FRAMEWORK"
  mv "$tmp/$FRAMEWORK" "$EXPORT_DIR/$FRAMEWORK"
  cp "$tmp/.chromium-version" "$EXPORT_DIR/.chromium-version"
  rm -rf "$tmp"
  echo "Pulled the Chrome engine (Chromium $built) into $EXPORT_DIR"
  du -sh "$EXPORT_DIR/$FRAMEWORK"
}

case "$COMMAND" in
  push)
    push_tools
    ;;
  prepare|apply|gen|build|package|all)
    resolve_version
    push_tools
    run_remote "$COMMAND"
    ;;
  status)
    status_remote
    ;;
  wait)
    wait_remote
    ;;
  pull)
    pull
    ;;
  help|-h|--help)
    cat <<'EOF'
Usage: ./script/chrome_engine.sh <command>

Builds the Chrome engine's framework (Chrome's framework with Chromium/engine)
for macOS arm64 on a Linux host and brings it to this Mac.

  prepare  copy the CEF build root's Chromium checkout without CEF (once per
           base), revert CEF's changes, apply the cross-build fixes and
           OpenArc's layer, gn gen out/OpenArc_arm64
  apply    OpenArc's layer, hooks, branding and patches (Chromium/engine/apply.sh)
  gen      gn gen out/OpenArc_arm64
  build    apply, then build chrome_framework (incremental)
  package  put the framework in the host's artifacts/dist
  all      prepare, build and package
  status   last lines of the running command's log
  wait     wait until the running command ends
  pull     copy the framework to ThirdParty/chrome-engine/export, where the
           app build stages it from

Remote commands push script/cef_cross, Chromium/engine and the contract header
first and run in tmux; set WAIT=1 to wait for them.

Environment:
  OPENARC_CEF_REMOTE_HOST             ssh host (default wsl)
  OPENARC_CHROME_ENGINE_REMOTE_ROOT   engine build root on the host
                                      (default ~/chrome-engine)
  OPENARC_CEF_REMOTE_ROOT             CEF build root on the host, whose
                                      checkout, depot_tools and hermetic Xcode
                                      the engine uses (default ~/cef-mac)
  OPENARC_CEF_XCODE                   Xcode whose strip the pull uses
                                      (default Xcode 26.6)
  CHROMIUM_TAG                        the Chromium to build; by default the
                                      exported CEF's
  EXTRA_GN_ARGS                       extra lines for args.gn
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
