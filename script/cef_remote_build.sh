#!/usr/bin/env bash
# Builds OpenArc's CEF on the Linux build host and brings it to this Mac.
# See docs/cef-build.md.
set -euo pipefail

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_HOST="${OPENARC_CEF_REMOTE_HOST:-wsl}"
# Relative paths are taken from the remote home directory.
REMOTE_ROOT="${OPENARC_CEF_REMOTE_ROOT:-cef-mac}"
TMUX_SESSION="${OPENARC_CEF_REMOTE_SESSION:-openarc-cef}"
# The Xcode whose macOS SDK the framework is built against; the same one
# script/chromium_source.sh uses on a Mac.
CEF_XCODE="${OPENARC_CEF_XCODE:-/Applications/Xcode-26.6.0.app}"
CHROMIUM_FORK_MARKER=".openarc-chromium-fork"

primary_checkout_root() {
  local common
  common="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}

# Exports live in the primary checkout, which every worktree links to.
CEF_DIR="$(primary_checkout_root)/ThirdParty/cef"
EXPORT_ROOT="$CEF_DIR/export"

remote_root_expr() {
  if [[ "$REMOTE_ROOT" == /* ]]; then
    printf '%s' "$REMOTE_ROOT"
  else
    printf '$HOME/%s' "$REMOTE_ROOT"
  fi
}

remote() {
  ssh "$REMOTE_HOST" "$@"
}

define_from_header() {
  sed -n "s/^#define $1 \"\{0,1\}\([^\" ]*\)\"\{0,1\}.*/\1/p" "$2" | head -n 1
}

# The baseline to build: the current export's cef_version.h unless
# CEF_COMMIT and CHROMIUM_TAG (and CEF_BRANCH) are given to move it.
resolve_versions() {
  local header="$EXPORT_ROOT/include/cef_version.h"
  if [[ -z "${CEF_COMMIT:-}" || -z "${CHROMIUM_TAG:-}" ]]; then
    [[ -f "$header" ]] || { echo "error: no $header; set CEF_BRANCH, CEF_COMMIT and CHROMIUM_TAG" >&2; exit 1; }
    CEF_COMMIT="${CEF_COMMIT:-$(define_from_header CEF_COMMIT_HASH "$header")}"
    CHROMIUM_TAG="${CHROMIUM_TAG:-$(define_from_header CHROME_VERSION_MAJOR "$header").$(define_from_header CHROME_VERSION_MINOR "$header").$(define_from_header CHROME_VERSION_BUILD "$header").$(define_from_header CHROME_VERSION_PATCH "$header")}"
  fi
  # CEF branches are named after the Chromium build number.
  CEF_BRANCH="${CEF_BRANCH:-$(cut -d. -f3 <<<"$CHROMIUM_TAG")}"
  echo "CEF $CEF_BRANCH at $CEF_COMMIT, Chromium $CHROMIUM_TAG"
}

push_tools() {
  local root
  root="$(remote_root_expr)"
  remote "mkdir -p \"$root/openarc\""
  rsync -a --delete "$ROOT_DIR/script/cef_cross/" "$REMOTE_HOST:$REMOTE_ROOT/openarc/tools/"
  rsync -a --delete --exclude .gitkeep "$ROOT_DIR/Chromium/chromium_src/" "$REMOTE_HOST:$REMOTE_ROOT/openarc/chromium_src/"
  echo "Pushed script/cef_cross and Chromium/chromium_src to $REMOTE_HOST:$REMOTE_ROOT/openarc"
}

# Copies the macOS SDK and Xcode's version.plist into the host's hermetic Xcode.
push_xcode() {
  local sdks="$CEF_XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
  local sdk
  sdk="MacOSX$(DEVELOPER_DIR="$CEF_XCODE/Contents/Developer" xcrun --sdk macosx --show-sdk-version).sdk"
  local dest="$REMOTE_ROOT/xcode_binaries/Contents"
  remote "mkdir -p \"$(remote_root_expr)/xcode_binaries/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs\" \"$(remote_root_expr)/xcode_binaries/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin\""
  rsync -t "$CEF_XCODE/Contents/version.plist" "$REMOTE_HOST:$dest/version.plist"
  # Times but not permissions: Linux cannot set a symlink's mode, and a changed
  # header time would rebuild the whole tree.
  rsync -rlt --delete "$sdks/MacOSX.sdk/" "$REMOTE_HOST:$dest/Developer/Platforms/MacOSX.platform/Developer/SDKs/$sdk/"
  local link
  link="$(remote_root_expr)/xcode_binaries/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  remote "[ \"\$(readlink \"$link\")\" = \"$sdk\" ] || ln -sfn \"$sdk\" \"$link\""
  echo "Pushed $sdk from $CEF_XCODE"
}

# Runs a cef_cross.sh command in a detached tmux session on the host, so a
# dropped connection does not stop a build. The log ends with "exit <status>".
run_remote() {
  local command="$1"
  local root
  root="$(remote_root_expr)"
  local env="CEF_CROSS_ROOT=\"$root\" CEF_BRANCH=${CEF_BRANCH:-} CEF_COMMIT=${CEF_COMMIT:-} CHROMIUM_TAG=${CHROMIUM_TAG:-}"
  [[ -n "${EXTRA_GN_DEFINES:-}" ]] && env="$env EXTRA_GN_DEFINES='$EXTRA_GN_DEFINES'"
  local log="$root/logs/$command.log"
  if remote "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
    echo "error: tmux session $TMUX_SESSION is still running on $REMOTE_HOST; see ./script/cef_remote_build.sh status" >&2
    exit 1
  fi
  remote "mkdir -p \"$root/logs\" && ln -sfn \"$command.log\" \"$root/logs/latest.log\" && tmux new-session -d -s $TMUX_SESSION \"$env bash \\\"$root/openarc/tools/cef_cross.sh\\\" $command > \\\"$log\\\" 2>&1; echo exit \\\$? >> \\\"$log\\\"\""
  echo "Started '$command' on $REMOTE_HOST (tmux $TMUX_SESSION), log $REMOTE_ROOT/logs/$command.log"
  if [[ "${WAIT:-0}" == "1" ]]; then
    wait_remote
  else
    echo "Follow with ./script/cef_remote_build.sh status, or wait with ./script/cef_remote_build.sh wait"
  fi
}

status_remote() {
  remote "tail -n ${LINES_SHOWN:-5} \"$(remote_root_expr)/logs/latest.log\""
}

wait_remote() {
  local last
  while true; do
    last="$(remote "tail -n 1 \"$(remote_root_expr)/logs/latest.log\"")"
    case "$last" in
      "exit 0") echo "Remote command finished"; return 0 ;;
      exit\ *) LINES_SHOWN=30 status_remote; echo "error: remote command failed ($last)" >&2; return 1 ;;
    esac
    sleep 60
  done
}

strip_framework() {
  local framework="$1"
  local binary
  while IFS= read -r -d '' binary; do
    xcrun strip -x "$binary"
  done < <(find "$framework" -type f \( -name "Chromium Embedded Framework" -o -name "*.dylib" \) -print0)
}

# Copies the host's distribution into ThirdParty/cef/export-<major> in the
# primary checkout and gives it the export layout: local symbols stripped,
# Debug pointing at Release (only Release CEF is built; the app stages Release
# CEF for Debug builds too) and the fork marker.
pull() {
  local tmp="$CEF_DIR/.export-pull.tmp"
  mkdir -p "$tmp"
  rsync -a --delete "$REMOTE_HOST:$REMOTE_ROOT/artifacts/dist/" "$tmp/"
  local header="$tmp/include/cef_version.h"
  [[ -f "$header" ]] || { echo "error: the distribution has no include/cef_version.h" >&2; exit 1; }
  local framework="$tmp/Release/Chromium Embedded Framework.framework"
  [[ -d "$framework" ]] || { echo "error: the distribution has no Release framework" >&2; exit 1; }

  DEVELOPER_DIR="$CEF_XCODE/Contents/Developer" strip_framework "$framework"
  rm -rf "$tmp/Debug"
  ln -s Release "$tmp/Debug"
  touch "$tmp/$CHROMIUM_FORK_MARKER"

  local major version dest
  major="$(define_from_header CEF_VERSION_MAJOR "$header")"
  version="$(define_from_header CEF_VERSION "$header")"
  dest="$CEF_DIR/export-$major"
  if [[ -e "$dest" && "$(cd "$dest" && pwd -P)" == "$(cd "$EXPORT_ROOT" && pwd -P)" ]]; then
    echo "error: $dest is the current export; pull into it would replace it in place" >&2
    echo "Run ./script/cef_remote_build.sh install $major after moving it aside." >&2
    exit 1
  fi
  rm -rf "$dest"
  mv "$tmp" "$dest"
  echo "Pulled $version into $dest"
  echo "Try it in one checkout with ./script/cef_remote_build.sh use $major,"
  echo "or make it the export for all with ./script/cef_remote_build.sh install $major."
}

# Points this checkout's ThirdParty/cef/export at export-<major> only.
use_export() {
  local major="$1"
  local target="$CEF_DIR/export-$major"
  [[ -d "$target" ]] || { echo "error: no $target" >&2; exit 1; }
  local link="$ROOT_DIR/ThirdParty/cef/export"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "error: $link is a directory, not a link; use install in the primary checkout" >&2
    exit 1
  fi
  ln -sfn "$target" "$link"
  "$ROOT_DIR/script/chromium.sh" root Release >/dev/null
  echo "This checkout now builds against $target"
}

# Makes export-<major> the shared export and keeps the previous one as
# export-<its major>. Running it again with the old major swaps back.
install_export() {
  local major="$1"
  local target="$CEF_DIR/export-$major"
  [[ -d "$target" ]] || { echo "error: no $target" >&2; exit 1; }
  if [[ -d "$EXPORT_ROOT" && ! -L "$EXPORT_ROOT" ]]; then
    local old
    old="$(define_from_header CEF_VERSION_MAJOR "$EXPORT_ROOT/include/cef_version.h")"
    [[ -n "$old" && ! -e "$CEF_DIR/export-$old" ]] || { echo "error: cannot move the current export aside to export-$old" >&2; exit 1; }
    mv "$EXPORT_ROOT" "$CEF_DIR/export-$old"
    echo "Moved the previous export to $CEF_DIR/export-$old"
  fi
  mv "$target" "$EXPORT_ROOT"
  "$(primary_checkout_root)/script/chromium.sh" root Release >/dev/null
  echo "ThirdParty/cef/export is now $(define_from_header CEF_VERSION "$EXPORT_ROOT/include/cef_version.h")"
}

case "$COMMAND" in
  push)
    push_tools
    ;;
  xcode)
    push_xcode
    ;;
  fetch|prepare|apply-overrides|build|package|all)
    resolve_versions
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
  use)
    use_export "${1:?usage: use <major>}"
    ;;
  install)
    install_export "${1:?usage: install <major>}"
    ;;
  help|-h|--help)
    cat <<'EOF'
Usage: ./script/cef_remote_build.sh <command>

Builds CEF for macOS arm64 on a Linux host and brings it to this Mac.

  xcode            copy the macOS SDK of OPENARC_CEF_XCODE to the host
  fetch            check out CEF and Chromium (once per base)
  prepare          copy CEF into src/cef, apply cross-build fixes and OpenArc's
                   CEF patch overrides, run CEF's hook and gn gen
  apply-overrides  copy Chromium/chromium_src over the tree
  build            apply-overrides, then build cef_framework (incremental)
  package          make the minimal binary distribution
  all              prepare, apply-overrides, build and package
  status           last lines of the running command's log
  wait             wait until the running command ends
  pull             copy the distribution to ThirdParty/cef/export-<major>
  use <major>      point this checkout's export at export-<major>
  install <major>  make export-<major> the shared export; the old one is kept
                   as export-<old major>

Remote commands push script/cef_cross and Chromium/chromium_src first and run
in tmux; set WAIT=1 to wait for them.

Environment:
  OPENARC_CEF_REMOTE_HOST   ssh host (default wsl)
  OPENARC_CEF_REMOTE_ROOT   build root on the host (default ~/cef-mac)
  OPENARC_CEF_XCODE         Xcode with the SDK (default Xcode 26.6)
  CEF_BRANCH, CEF_COMMIT, CHROMIUM_TAG
                            the base to build; by default the current
                            ThirdParty/cef/export/include/cef_version.h
  EXTRA_GN_DEFINES          extra GN args for prepare
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
