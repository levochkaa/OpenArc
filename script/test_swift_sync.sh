#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/Backend"

if [[ "$(node -p 'process.versions.node.split(".")[0]')" != 26 ]]; then
  echo "Swift sync integration tests require Node.js 26." >&2
  exit 1
fi
if [[ ! -x node_modules/.bin/tsx ]]; then
  echo "Run npm ci in Backend before running sync integration tests." >&2
  exit 1
fi
docker info >/dev/null

test_id="$(node -p 'require("node:crypto").randomBytes(8).toString("hex")')"
container_name="thebrowser-swift-sync-test-$test_id"
database_name="thebrowser_sync_test_$test_id"
fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/thebrowser-swift-sync.XXXXXX")"
fixture_path="$fixture_directory/fixture.json"
report_path="$fixture_directory/completed.json"
fixture_log="$fixture_directory/fixture.log"
container_id=""
fixture_pid=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ "$status" != 0 ]]; then
    cat "$fixture_log" >&2 2>/dev/null || true
    if [[ -n "$container_id" ]]; then docker logs --tail 40 "$container_id" >&2 || true; fi
  fi
  if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null || true; fi
  rm -rf "$fixture_directory"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This disposable database has no persistent volume and only a loopback port.
container_id="$(docker run --detach --rm --name "$container_name" \
  --label thebrowser.sync-test=true --publish 127.0.0.1::5432 \
  --env "POSTGRES_DB=$database_name" --env POSTGRES_USER=sync_test \
  --env POSTGRES_PASSWORD=disposable-local-test-password postgres:17)"

ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if docker exec "$container_id" pg_isready -U sync_test -d "$database_name" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "Disposable sync test database did not become ready." >&2
  exit 1
fi
database_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort}}' "$container_id")"
export THEBROWSER_SYNC_TEST_DATABASE_URL="postgres://sync_test:disposable-local-test-password@127.0.0.1:$database_port/$database_name"
node --import tsx tests/swift-sync-fixture.ts "$fixture_path" "$report_path" >"$fixture_log" 2>&1 &
fixture_pid=$!

ready=false
for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -s "$fixture_path" ]]; then ready=true; break; fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "Swift HTTP fixture did not become ready." >&2
  exit 1
fi

cd "$repo_root"
# Xcode forwards TEST_RUNNER_ variables to the hostless test process.
export TEST_RUNNER_THEBROWSER_SYNC_HTTP_FIXTURE="$fixture_path"
export THEBROWSER_SYNC_HTTP_FIXTURE="$fixture_path"
./build.sh test -- -only-testing:TheBrowserTests/BrowserSyncHTTPIntegrationTests

# A filtered or skipped suite must not make this explicit integration run green.
node --input-type=module - "$report_path" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(process.argv[2], "utf8"));
assert.deepEqual(report.completed, [
  "coordinator-delete-pending", "coordinator-lost-ack", "coordinator-move-first", "coordinator-patch-first",
  "coordinator-space-delete-move",
  "desktop-archive-restore", "desktop-auto-archive", "desktop-confirmed-close", "desktop-local-auto-archive",
  "edit-during-ack", "expiry-queue", "expiry-recovery", "expiry-response-limit", "explicit-group-replay", "explicit-local-first", "explicit-remote-first",
  "folder-activity-replay", "folder-adoption-paged", "folder-device-rotation", "folder-lost-ack", "folder-pending-delete", "folder-race", "folder-roundtrip",
  "global-favorite", "lost-ack", "offline-delete", "pending-navigation", "pending-parent-delete", "persistence-retry",
  "semantic-move-first", "semantic-patch-first"
]);
assert.ok(report.attempts > 0);
console.log("Swift production HTTP sync: all 31 scenarios completed");
JS
