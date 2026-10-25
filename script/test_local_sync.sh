#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/Backend"

if [[ "$(node -p 'process.versions.node.split(".")[0]')" != 26 ]]; then
  echo "Sync integration tests require Node.js 26." >&2
  exit 1
fi
if [[ ! -x node_modules/.bin/tsx ]]; then
  echo "Run npm ci in Backend before running sync integration tests." >&2
  exit 1
fi
docker info >/dev/null
OPENARC_SYNC_SERVER_BINARY="$("$repo_root/script/build_sync_server.sh")"
export OPENARC_SYNC_SERVER_BINARY
# Unit and database-free HTTP tests, including the receipt digest fixture.
PATH="/opt/homebrew/opt/rustup/bin:$PATH" cargo test --quiet

test_id="$(node -p 'require("node:crypto").randomBytes(8).toString("hex")')"
container_name="openarc-sync-test-$test_id"
database_name="openarc_sync_test_$test_id"
container_id=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$container_id" ]]; then
    if [[ "$status" != 0 ]]; then
      docker logs --tail 40 "$container_id" >&2 || true
    fi
    docker rm --force "$container_id" >/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This container has no persistent volume and cannot reach an existing database.
container_id="$(docker run --detach --rm --name "$container_name" \
  --label openarc.sync-test=true \
  --publish 127.0.0.1::5432 \
  --env "POSTGRES_DB=$database_name" \
  --env POSTGRES_USER=sync_test \
  --env POSTGRES_PASSWORD=disposable-local-test-password \
  postgres:17)"

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
export DATABASE_URL="$OPENARC_SYNC_TEST_DATABASE_URL"
export APPLE_CLIENT_ID=com.openarc.sync-integration-tests
export JWT_SECRET=local-integration-only-secret-at-least-thirty-two-bytes
export JWT_ISSUER=openarc-sync-integration-tests
export JWT_AUDIENCE=openarc-sync-integration-clients

# The suite seeds v1 fixtures before running the server's migrate command.
node --test --import tsx --test-reporter spec tests/sync.integration.test.ts
