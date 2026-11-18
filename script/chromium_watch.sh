#!/usr/bin/env bash
# The Chromium update automation from the Mac: runs script/cef_cross/chromium_watch.py
# here or on the Linux build host. See docs/chromium-updates.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT_DIR/script/cef_cross/chromium_watch.py"
REMOTE_HOST="${OPENARC_CEF_REMOTE_HOST:-wsl}"
REMOTE_ROOT="${OPENARC_CEF_REMOTE_ROOT:-cef-mac}"

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

remote_root_expr() {
  if [[ "$REMOTE_ROOT" == /* ]]; then printf '%s' "$REMOTE_ROOT"; else printf '$HOME/%s' "$REMOTE_ROOT"; fi
}

# Runs chromium_watch.py on the host from its copy of main (pushed by sync).
remote_watch() {
  local root args=""
  root="$(remote_root_expr)"
  [[ $# -gt 0 ]] && args="$(printf ' %q' "$@")"
  # The command goes in on stdin, so arguments need one level of quoting; a
  # login shell loads the host's ~/.env and PATH.
  printf 'CEF_CROSS_ROOT="%s" exec python3 -I "%s/openarc/main/tools/chromium_watch.py"%s\n' "$root" "$root" "$args" |
    ssh -o ConnectTimeout=15 "$REMOTE_HOST" 'bash -l -s'
}

remote_status_field() {
  remote_watch status --json | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

case "$COMMAND" in
  mac-tick|sync|notify)
    exec python3 -I "$WATCH" "$COMMAND" "$@"
    ;;
  status|check|done|retry)
    remote_watch "$COMMAND" "$@"
    ;;
  log)
    log="$(remote_status_field log)"
    [[ -n "$log" ]] || { echo "error: no update log yet" >&2; exit 1; }
    ssh "$REMOTE_HOST" "tail -n ${LINES_SHOWN:-40} $(printf '%q' "$log")"
    ;;
  merged)
    # The host's merged overrides into this checkout's Chromium/chromium_src.
    merged="$(remote_status_field merged_dir)"
    [[ -n "$merged" ]] || { echo "error: the host has no merged overrides" >&2; exit 1; }
    rsync -a --delete --exclude .gitkeep "$REMOTE_HOST:$merged/" "$ROOT_DIR/Chromium/chromium_src/"
    git -C "$ROOT_DIR" status --short -- Chromium/chromium_src
    if grep -rlE '^(<<<<<<<|>>>>>>>) ' "$ROOT_DIR/Chromium/chromium_src"; then
      echo "These files have conflict markers to resolve."
    fi
    ;;
  help|-h|--help)
    cat <<'EOF'
Usage: ./script/chromium_watch.sh <command> [args]

On the Linux build host (over ssh):
  status [--json]     the last update: version, phase, result, conflicts, timings
  check [--dry-run] [--baseline CEF_VERSION] [--no-github] [--force]
                      look for a newer stable now (the timer does it every 30 min)
  done --result released|abandoned|failed [--note TEXT]
                      the update is finished; lets the next one start
  retry [--key KEY]   build the last attempted version again on the next check
  log                 the end of the update's log (LINES_SHOWN=40)

On this Mac:
  merged              copy the host's merged overrides into Chromium/chromium_src
  sync [--dry-run]    push main's script/cef_cross, Chromium/chromium_src and the
                      export's version to the host
  mac-tick [--dry-run]
                      what the LaunchAgent runs: sync, read the status, start
                      the agent thread for a finished build
  notify [--test] TEXT
                      Telegram message (KODYA_BOT_TOKEN, KODYA_CHAT_ID)

Environment: OPENARC_CEF_REMOTE_HOST (default wsl), OPENARC_CEF_REMOTE_ROOT
(default ~/cef-mac on the host).
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'; see --help" >&2
    exit 2
    ;;
esac
