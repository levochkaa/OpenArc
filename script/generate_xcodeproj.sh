#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/script/bazel_environment.sh"
configure_bazel_environment

cd "$ROOT_DIR"

bazel run "${BAZEL_BUILD_ARGS[@]}" //:xcodeproj
