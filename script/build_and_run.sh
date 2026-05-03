#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: $0 [run|build|debug|logs|telemetry|verify]" >&2
  exit 1
}

case "$MODE" in
  run)
    exec "$ROOT_DIR/script/run.sh" run
    ;;
  build)
    exec "$ROOT_DIR/script/build.sh"
    ;;
  --debug|debug)
    exec "$ROOT_DIR/script/run.sh" "$MODE"
    ;;
  --logs|logs)
    exec "$ROOT_DIR/script/run.sh" "$MODE"
    ;;
  --telemetry|telemetry)
    exec "$ROOT_DIR/script/run.sh" "$MODE"
    ;;
  --verify|verify)
    exec "$ROOT_DIR/script/build.sh"
    ;;
  *)
    usage
    ;;
esac
