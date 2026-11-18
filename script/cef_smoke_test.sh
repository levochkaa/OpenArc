#!/usr/bin/env bash
# Runtime smoke test for OpenArc's engine (CEF/Chromium) after an update.
# Usage: script/cef_smoke_test.sh <OpenArc.app> [options]; --help lists the checks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
exec "$PYTHON" -I "$SCRIPT_DIR/cef_smoke_test.py" "$@"
