#!/usr/bin/env bash
# Serves the Swift HTTP sync fixture: a disposable PostgreSQL container, the
# Rust sync server and Backend/tests/swift-sync-fixture.ts.
#
# Usage: script/sync_fixture_host.sh desktop|mobile FIXTURE_DIRECTORY
#
# Writes FIXTURE_DIRECTORY/fixture.json and, as scenarios complete,
# FIXTURE_DIRECTORY/completed.json, then prints "fixture-ready". It runs until
# SIGTERM/SIGINT/SIGHUP or, when stdin is a pipe (an ssh session), until stdin
# closes; then it stops the fixture and removes the container.
# OPENARC_SYNC_FIXTURE_INSTALL=1 runs npm ci in Backend when its lockfile changed.
set -euo pipefail

suite="${1:-}"
fixture_directory="${2:-}"
if [[ "$suite" != desktop && "$suite" != mobile ]] || [[ ! -d "$fixture_directory" ]]; then
  echo "Usage: script/sync_fixture_host.sh desktop|mobile FIXTURE_DIRECTORY" >&2
  exit 2
fi
fixture_directory="$(cd "$fixture_directory" && pwd)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/Backend"

if [[ "$(node -p 'process.versions.node.split(".")[0]')" != 26 ]]; then
  echo "Sync integration tests require Node.js 26." >&2
  exit 1
fi
if [[ "${OPENARC_SYNC_FIXTURE_INSTALL:-}" == 1 ]]; then
  lock_digest="$(node -p 'require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync("package-lock.json")).digest("hex")')"
  if [[ "$(cat node_modules/.openarc-lock-digest 2>/dev/null || true)" != "$lock_digest" ]]; then
    npm ci --silent --no-audit --no-fund >&2
    echo "$lock_digest" >node_modules/.openarc-lock-digest
  fi
fi
if [[ ! -x node_modules/.bin/tsx ]]; then
  echo "Run npm ci in Backend before running sync integration tests." >&2
  exit 1
fi
docker info >/dev/null
OPENARC_SYNC_SERVER_BINARY="$("$repo_root/script/build_sync_server.sh")"
export OPENARC_SYNC_SERVER_BINARY

test_id="$(node -p 'require("node:crypto").randomBytes(8).toString("hex")')"
container_name="openarc-$suite-sync-test-$test_id"
database_name="openarc_sync_test_$test_id"
fixture_path="$fixture_directory/fixture.json"
report_path="$fixture_directory/completed.json"
fixture_log="$fixture_directory/fixture.log"
container_id=""
fixture_pid=""
watcher_pid=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$watcher_pid" ]]; then kill "$watcher_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ "$status" != 0 && "$status" != 143 && "$status" != 129 ]]; then
    cat "$fixture_log" >&2 2>/dev/null || true
    if [[ -n "$container_id" ]]; then docker logs --tail 40 "$container_id" >&2 || true; fi
  fi
  if [[ -n "$container_id" ]]; then docker rm --force --volumes "$container_id" >/dev/null || true; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The data directory is a tmpfs, so the disposable database leaves no volume
# behind. Only a loopback port is published.
container_id="$(docker run --detach --rm --name "$container_name" \
  --label openarc.sync-test=true --publish 127.0.0.1::5432 \
  --tmpfs /var/lib/postgresql/data:rw \
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
export OPENARC_SYNC_TEST_DATABASE_URL="postgres://sync_test:disposable-local-test-password@127.0.0.1:$database_port/$database_name"
OPENARC_SYNC_FIXTURE_SUITE="$suite" node --import tsx tests/swift-sync-fixture.ts "$fixture_path" "$report_path" \
  >"$fixture_log" 2>&1 </dev/null &
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
echo fixture-ready

if [[ -p /dev/stdin || -S /dev/stdin ]]; then
  # An ssh caller keeps stdin open for as long as it uses the fixture.
  exec 4<&0
  (cat <&4 >/dev/null; kill -TERM $$ 2>/dev/null) &
  watcher_pid=$!
fi
set +e
wait "$fixture_pid"
fixture_status=$?
fixture_pid=""
echo "Swift HTTP fixture exited ($fixture_status)." >&2
exit 1
