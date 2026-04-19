#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_SPEC="$ROOT_DIR/project.yml"

if [[ ! -f "$PROJECT_SPEC" ]]; then
  echo "error: missing project spec at $PROJECT_SPEC" >&2
  exit 1
fi

echo "Generating TheBrowser.xcodeproj from project.yml"
xcodegen generate --spec "$PROJECT_SPEC"
