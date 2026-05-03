#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"
mkdir -p "$HOME/.cache/bazel/thebrowser/disk" "$HOME/.cache/bazel/thebrowser/repository"

bazel run //:xcodeproj
