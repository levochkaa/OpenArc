#!/usr/bin/env bash
# Installs the Chromium update automation: the Mac's LaunchAgent and the Linux
# build host's systemd user timer. See docs/chromium-updates.md.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./script/automation_install.sh install|uninstall|status [--dry-run] [--mac-only|--host-only]

  install    render and load the LaunchAgent (every OPENARC_AUTOMATION_INTERVAL
             seconds, default 300), push main's tools to the host and enable its
             timer (every 30 minutes)
  uninstall  unload and remove both; state and logs stay
  status     whether both run, their last lines of log, the host's update status

--dry-run prints the rendered files and the commands instead of running them.
The installed LaunchAgent runs the primary checkout's main, so land the
automation on main before installing it.
EOF
  exit 2
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || usage
shift
DRY_RUN=0
DO_MAC=1
DO_HOST=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --mac-only) DO_HOST=0 ;;
    --host-only) DO_MAC=0 ;;
    *) usage ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="$(dirname "$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)")"
TEMPLATES="$ROOT_DIR/script/automation"
LABEL="com.levochkaa.OpenArc.chromium-update"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/OpenArc-Automation"
INTERVAL="${OPENARC_AUTOMATION_INTERVAL:-300}"
REMOTE_HOST="${OPENARC_CEF_REMOTE_HOST:-wsl}"
REMOTE_ROOT="${OPENARC_CEF_REMOTE_ROOT:-cef-mac}"
UNIT="openarc-chromium-watch"

say() { printf '%s\n' "$*"; }

# Runs a command, or prints it in a dry run.
act() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Writes stdin to a local file, or prints it in a dry run.
write_file() {
  local path="$1"
  if [[ "$DRY_RUN" == 1 ]]; then
    say "--- would write $path"
    cat
    say "---"
  else
    mkdir -p "$(dirname "$path")"
    cat >"$path"
  fi
}

# Writes stdin to a file on the host, or prints it in a dry run.
write_remote_file() {
  local path="$1"
  if [[ "$DRY_RUN" == 1 ]]; then
    say "--- would write $REMOTE_HOST:$path"
    cat
    say "---"
  else
    ssh "$REMOTE_HOST" "mkdir -p \"\$(dirname $path)\" && cat > $path"
  fi
}

tool_path() {
  local dirs="" tool dir
  for tool in t3 git rsync ssh; do
    dir="$(dirname "$(command -v "$tool" 2>/dev/null || echo /usr/bin/true)")"
    case ":$dirs:" in *":$dir:"*) ;; *) dirs="${dirs:+$dirs:}$dir" ;; esac
  done
  for dir in /usr/bin /bin /usr/sbin /sbin; do
    case ":$dirs:" in *":$dir:"*) ;; *) dirs="$dirs:$dir" ;; esac
  done
  printf '%s' "$dirs"
}

# A stable path, not the versioned one a Homebrew python3 resolves to.
python_path() {
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return; }
  done
  command -v python3
}

render_plist() {
  local content
  content="$(<"$TEMPLATES/chromium-update.plist.template")"
  content="${content//@LABEL@/$LABEL}"
  content="${content//@PYTHON@/$(python_path)}"
  content="${content//@CHECKOUT@/$CHECKOUT}"
  content="${content//@PATH@/$(tool_path)}"
  content="${content//@REMOTE_HOST@/$REMOTE_HOST}"
  content="${content//@REMOTE_ROOT@/$REMOTE_ROOT}"
  content="${content//@INTERVAL@/$INTERVAL}"
  content="${content//@LOG@/$LOG_DIR/chromium-update.log}"
  printf '%s\n' "$content"
}

render_unit() {
  local root content
  if [[ "$REMOTE_ROOT" == /* ]]; then root="$REMOTE_ROOT"; else root="%h/$REMOTE_ROOT"; fi
  content="$(<"$TEMPLATES/$1")"
  printf '%s\n' "${content//@ROOT@/$root}"
}

install_mac() {
  if ! git -C "$CHECKOUT" cat-file -e main:script/cef_cross/chromium_watch.py 2>/dev/null; then
    if [[ "$DRY_RUN" == 1 ]]; then
      say "warning: main in $CHECKOUT has no script/cef_cross/chromium_watch.py yet; land the automation first"
    else
      say "error: main in $CHECKOUT has no script/cef_cross/chromium_watch.py; land the automation on main first" >&2
      exit 1
    fi
  fi
  command -v t3 >/dev/null || say "warning: no t3 on PATH; the LaunchAgent cannot start agent threads"
  act mkdir -p "$LOG_DIR"
  render_plist | write_file "$PLIST"
  act launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  act launchctl bootstrap "gui/$(id -u)" "$PLIST"
  say "Mac: $LABEL runs every ${INTERVAL}s, log $LOG_DIR/chromium-update.log"
}

install_host() {
  local sync_args=(sync)
  [[ "$DRY_RUN" == 1 ]] && sync_args+=(--dry-run)
  python3 -I "$ROOT_DIR/script/cef_cross/chromium_watch.py" "${sync_args[@]}"
  render_unit "$UNIT.service" | write_remote_file ".config/systemd/user/$UNIT.service"
  render_unit "$UNIT.timer" | write_remote_file ".config/systemd/user/$UNIT.timer"
  act ssh "$REMOTE_HOST" "systemctl --user daemon-reload && systemctl --user enable --now $UNIT.timer"
  if [[ "$(ssh "$REMOTE_HOST" 'loginctl show-user "$USER" -p Linger --value' 2>/dev/null)" != "yes" ]]; then
    say "warning: lingering is off on $REMOTE_HOST; the timer runs only while someone is logged in (loginctl enable-linger)"
  fi
  say "Host: $UNIT.timer on $REMOTE_HOST checks every 30 minutes"
}

uninstall_mac() {
  act launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  act rm -f "$PLIST"
  say "Mac: removed $LABEL"
}

uninstall_host() {
  act ssh "$REMOTE_HOST" "systemctl --user disable --now $UNIT.timer 2>/dev/null; rm -f ~/.config/systemd/user/$UNIT.service ~/.config/systemd/user/$UNIT.timer; systemctl --user daemon-reload"
  say "Host: removed $UNIT.timer"
}

show_status() {
  if [[ "$DO_MAC" == 1 ]]; then
    say "== Mac LaunchAgent $LABEL"
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E '^\s+(state|last exit code|run interval) ' || say "not loaded"
    tail -n 5 "$LOG_DIR/chromium-update.log" 2>/dev/null || true
  fi
  if [[ "$DO_HOST" == 1 ]]; then
    say "== $REMOTE_HOST $UNIT.timer"
    ssh "$REMOTE_HOST" "systemctl --user list-timers $UNIT.timer --no-pager; journalctl --user -u $UNIT.service -n 5 --no-pager -o cat" || true
    say "== update status"
    "$ROOT_DIR/script/chromium_watch.sh" status || true
  fi
}

case "$COMMAND" in
  install)
    if [[ "$DO_HOST" == 1 ]]; then install_host; fi
    if [[ "$DO_MAC" == 1 ]]; then install_mac; fi
    ;;
  uninstall)
    if [[ "$DO_MAC" == 1 ]]; then uninstall_mac; fi
    if [[ "$DO_HOST" == 1 ]]; then uninstall_host; fi
    ;;
  status)
    show_status
    ;;
  *)
    usage
    ;;
esac
