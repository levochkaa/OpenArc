#!/usr/bin/env bash
# Runs the desktop Swift sync suite against the production HTTP server.
#
# By default PostgreSQL (Docker), the Rust server and the fixture run on this
# Mac. OPENARC_SYNC_TEST_SSH_HOST=HOST runs them on HOST instead (it needs
# Node.js 26 and Docker; Rust is optional there): Backend/ and the fixture
# scripts are copied to ~/.cache/openarc-sync-test/<checkout> on HOST, and the
# fixture's two ports are forwarded over ssh.
#
# OPENARC_SYNC_TEST_ONLY="name() other()" runs only those tests of the suite
# and skips the check that every scenario completed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
ssh_host="${OPENARC_SYNC_TEST_SSH_HOST:-}"

fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/openarc-swift-sync.XXXXXX")"
fixture_path="$fixture_directory/fixture.json"
report_path="$fixture_directory/completed.json"
host_log="$fixture_directory/host.log"
host_pid=""
tunnel_pid=""
keepalive=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$tunnel_pid" ]]; then kill "$tunnel_pid" 2>/dev/null || true; fi
  if [[ -n "$keepalive" ]]; then exec 3>&-; fi
  if [[ -n "$host_pid" ]]; then
    # A local host stops on SIGTERM; a remote one when its stdin closes.
    if [[ -z "$ssh_host" ]]; then kill "$host_pid" 2>/dev/null || true; fi
    wait "$host_pid" 2>/dev/null || true
  fi
  if [[ "$status" != 0 ]]; then cat "$host_log" >&2 2>/dev/null || true; fi
  rm -rf "$fixture_directory"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_host() {
  local attempt
  # A first remote run installs npm packages and builds the server.
  for ((attempt = 0; attempt < 12000; attempt++)); do
    if grep -q '^fixture-ready' "$host_log" 2>/dev/null; then return 0; fi
    if ! kill -0 "$host_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  echo "Swift HTTP fixture did not become ready." >&2
  exit 1
}

if [[ -z "$ssh_host" ]]; then
  "$repo_root/script/sync_fixture_host.sh" desktop "$fixture_directory" </dev/null >"$host_log" 2>&1 &
  host_pid=$!
  wait_for_host
else
  remote_root=".cache/openarc-sync-test/$(basename "$repo_root")"
  ssh "$ssh_host" "mkdir -p $remote_root/script"
  rsync -a --delete --exclude node_modules --exclude target --exclude .env "$repo_root/Backend/" "$ssh_host:$remote_root/Backend/"
  rsync -a "$repo_root/script/sync_fixture_host.sh" "$repo_root/script/build_sync_server.sh" "$ssh_host:$remote_root/script/"
  remote_directory="$(ssh "$ssh_host" 'mktemp -d /tmp/openarc-swift-sync.XXXXXX')"
  # The host runs until this script closes the pipe on descriptor 3.
  mkfifo "$fixture_directory/keepalive"
  ssh "$ssh_host" "bash -lc 'cd $remote_root && trap \"rm -rf $remote_directory\" EXIT && OPENARC_SYNC_FIXTURE_INSTALL=1 script/sync_fixture_host.sh desktop $remote_directory'" \
    <"$fixture_directory/keepalive" >"$host_log" 2>&1 &
  host_pid=$!
  exec 3>"$fixture_directory/keepalive"
  keepalive=1
  wait_for_host
  ssh "$ssh_host" "cat $remote_directory/fixture.json" >"$fixture_directory/remote.json"
  # Forward the fixture's proxy and control ports to free local ports and
  # point the local copy of the fixture at them.
  forwards="$(node --input-type=module - "$fixture_directory/remote.json" "$fixture_path" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
const [remotePath, localPath] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(remotePath, "utf8"));
async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}
const forwards = [];
for (const key of ["baseURL", "controlURL"]) {
  const url = new URL(fixture[key]);
  const port = await freePort();
  forwards.push(`-L 127.0.0.1:${port}:127.0.0.1:${url.port}`);
  url.port = String(port);
  fixture[key] = url.toString().replace(/\/$/, "");
}
writeFileSync(localPath, JSON.stringify(fixture), { mode: 0o600 });
console.log(forwards.join(" "));
JS
)"
  # shellcheck disable=SC2086
  ssh -N -o ExitOnForwardFailure=yes $forwards "$ssh_host" &
  tunnel_pid=$!
  control_url="$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).controlURL' "$fixture_path")"
  tunnel_ready=false
  for ((attempt = 0; attempt < 100; attempt++)); do
    if curl --silent --output /dev/null --max-time 2 "$control_url"; then tunnel_ready=true; break; fi
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ "$tunnel_ready" != true ]]; then
    echo "The ssh tunnel to the fixture on $ssh_host did not open." >&2
    exit 1
  fi
fi

# Xcode forwards TEST_RUNNER_ variables to the hostless test process.
export TEST_RUNNER_OPENARC_SYNC_HTTP_FIXTURE="$fixture_path"
export OPENARC_SYNC_HTTP_FIXTURE="$fixture_path"
only_testing=()
for name in ${OPENARC_SYNC_TEST_ONLY:-}; do
  only_testing+=("-only-testing:OpenArcTests/BrowserSyncHTTPIntegrationTests/$name")
done
if [[ ${#only_testing[@]} == 0 ]]; then
  only_testing=(-only-testing:OpenArcTests/BrowserSyncHTTPIntegrationTests)
fi
./build.sh test -- "${only_testing[@]}"
if [[ -n "${OPENARC_SYNC_TEST_ONLY:-}" ]]; then exit 0; fi

if [[ -n "$ssh_host" ]]; then
  ssh "$ssh_host" "cat $remote_directory/completed.json" >"$report_path"
fi

# A filtered or skipped suite must not make this explicit integration run green.
node --input-type=module - "$report_path" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(process.argv[2], "utf8"));
assert.deepEqual(report.completed, [
  "coordinator-delete-pending", "coordinator-lost-ack", "coordinator-move-first", "coordinator-patch-first",
  "coordinator-space-delete-move",
  "desktop-archive-restore", "desktop-auto-archive", "desktop-confirmed-close", "desktop-local-auto-archive", "desktop-persistent-close", "desktop-persistent-removal",
  "edit-during-ack", "expiry-queue", "expiry-recovery", "expiry-response-limit", "explicit-group-replay", "explicit-local-first", "explicit-remote-first",
  "folder-activity-replay", "folder-adoption-paged", "folder-device-rotation", "folder-lost-ack", "folder-pending-delete", "folder-race", "folder-roundtrip",
  "global-favorite", "lost-ack", "offline-delete", "pending-navigation", "pending-parent-delete", "persistence-retry",
  "semantic-move-first", "semantic-patch-first"
]);
assert.ok(report.attempts > 0);
console.log("Swift production HTTP sync: all 33 scenarios completed");
JS
