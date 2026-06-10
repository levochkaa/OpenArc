#!/usr/bin/env bash

DEFAULT_THEBROWSER_DEVELOPER_DIR="/Applications/Xcode-26.5.0.app/Contents/Developer"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$DEFAULT_THEBROWSER_DEVELOPER_DIR}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: DEVELOPER_DIR '$DEVELOPER_DIR' does not exist" >&2
  exit 2
fi
