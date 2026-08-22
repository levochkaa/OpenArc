#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
SPARKLE_TOOLS_ROOT_IS_EXPLICIT=0
if [[ -n "${SPARKLE_TOOLS_ROOT+x}" ]]; then
  SPARKLE_TOOLS_ROOT_IS_EXPLICIT=1
fi
SPARKLE_TOOLS_ROOT="${SPARKLE_TOOLS_ROOT:-$ROOT_DIR/.build/sparkle}"
SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_ROOT/Sparkle-$SPARKLE_VERSION"
SPARKLE_TOOLS_ARCHIVE="$SPARKLE_TOOLS_ROOT/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_TOOLS_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

validate_sparkle_version() {
  if [[ ! "$SPARKLE_VERSION" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
    echo "error: unsafe Sparkle version '$SPARKLE_VERSION'" >&2
    return 2
  fi
}

sparkle_tools_ready_at() {
  local tools_dir="$1"
  [[ -x "$tools_dir/bin/generate_appcast" ]] &&
    [[ -x "$tools_dir/bin/generate_keys" ]] &&
    [[ -d "$tools_dir/Sparkle.framework" ]]
}

sparkle_tools_ready() {
  sparkle_tools_ready_at "$SPARKLE_TOOLS_DIR"
}

sparkle_primary_checkout_root() {
  local common_git_dir
  common_git_dir="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common_git_dir" && "$(basename "$common_git_dir")" == ".git" ]]; then
    dirname "$common_git_dir"
    return
  fi

  printf '%s\n' "$ROOT_DIR"
}

remove_incomplete_sparkle_tools() {
  if [[ -L "$SPARKLE_TOOLS_DIR" ]]; then
    rm -f "$SPARKLE_TOOLS_DIR"
  elif [[ -e "$SPARKLE_TOOLS_DIR" ]]; then
    rm -rf "$SPARKLE_TOOLS_DIR"
  fi
}

prepare_sparkle_tools_from_primary() {
  local refresh="${1:-0}"
  local primary_root
  local primary_tools_dir

  validate_sparkle_version

  if [[ "$SPARKLE_TOOLS_ROOT_IS_EXPLICIT" == "1" ]]; then
    return 1
  fi

  primary_root="$(sparkle_primary_checkout_root)"
  if [[ "$primary_root" == "$ROOT_DIR" ]]; then
    return 1
  fi

  primary_tools_dir="$primary_root/.build/sparkle/Sparkle-$SPARKLE_VERSION"
  if ! sparkle_tools_ready_at "$primary_tools_dir"; then
    return 1
  fi

  if sparkle_tools_ready && [[ "$refresh" != "1" ]]; then
    return 0
  fi

  remove_incomplete_sparkle_tools
  mkdir -p "$SPARKLE_TOOLS_ROOT"
  ln -s "$primary_tools_dir" "$SPARKLE_TOOLS_DIR"
  echo "Reusing Sparkle $SPARKLE_VERSION from $primary_tools_dir"
}

ensure_sparkle_tools() {
  local temporary_archive
  local temporary_tools_dir

  validate_sparkle_version

  if sparkle_tools_ready; then
    return
  fi

  if prepare_sparkle_tools_from_primary; then
    return
  fi

  remove_incomplete_sparkle_tools
  mkdir -p "$SPARKLE_TOOLS_ROOT"

  if [[ -f "$SPARKLE_TOOLS_ARCHIVE" ]] && ! tar -tJf "$SPARKLE_TOOLS_ARCHIVE" >/dev/null 2>&1; then
    rm -f "$SPARKLE_TOOLS_ARCHIVE"
  fi

  if [[ ! -f "$SPARKLE_TOOLS_ARCHIVE" ]]; then
    temporary_archive="$(mktemp "$SPARKLE_TOOLS_ROOT/.Sparkle-$SPARKLE_VERSION.tar.xz.XXXXXX")"
    if ! curl -fL "$SPARKLE_TOOLS_URL" -o "$temporary_archive"; then
      rm -f "$temporary_archive"
      return 1
    fi
    mv "$temporary_archive" "$SPARKLE_TOOLS_ARCHIVE"
  fi

  temporary_tools_dir="$(mktemp -d "$SPARKLE_TOOLS_ROOT/.Sparkle-$SPARKLE_VERSION.XXXXXX")"
  if ! tar -xJf "$SPARKLE_TOOLS_ARCHIVE" -C "$temporary_tools_dir"; then
    rm -rf "$temporary_tools_dir"
    rm -f "$SPARKLE_TOOLS_ARCHIVE"
    return 1
  fi

  mv "$temporary_tools_dir" "$SPARKLE_TOOLS_DIR"
  if ! sparkle_tools_ready; then
    remove_incomplete_sparkle_tools
    echo "error: Sparkle $SPARKLE_VERSION archive is missing required tools or framework" >&2
    return 1
  fi
}
