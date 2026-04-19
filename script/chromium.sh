#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
CONFIGURATION="${2:-Debug}"
CEF_VERSION="${CEF_VERSION:-141.0.5+gfe26daa+chromium-141.0.7390.55}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/ThirdParty/cef"
DOWNLOAD_DIR="$THIRD_PARTY_DIR/downloads"
WRAPPER_BUILD_DIR="$ROOT_DIR/.build/cef-wrapper"

case "$(uname -m)" in
  arm64)
    CEF_PLATFORM="macosarm64"
    PROJECT_ARCH="arm64"
    ;;
  x86_64)
    CEF_PLATFORM="macosx64"
    PROJECT_ARCH="x86_64"
    ;;
  *)
    echo "error: unsupported host architecture $(uname -m)" >&2
    exit 1
    ;;
esac

CEF_DISTRIBUTION="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
CEF_ARCHIVE="${CEF_DISTRIBUTION}.tar.bz2"
CEF_ARCHIVE_PATH="$DOWNLOAD_DIR/$CEF_ARCHIVE"
CEF_ROOT="$THIRD_PARTY_DIR/$CEF_DISTRIBUTION"
CURRENT_LINK="$THIRD_PARTY_DIR/current"
CEF_DOWNLOAD_URL="https://cef-builds.spotifycdn.com/${CEF_ARCHIVE//+/%2B}"
WRAPPER_LIB="$WRAPPER_BUILD_DIR/libcef_dll_wrapper/$CONFIGURATION/libcef_dll_wrapper.a"

ensure_directories() {
  mkdir -p "$DOWNLOAD_DIR"
  mkdir -p "$THIRD_PARTY_DIR"
}

download_cef_distribution() {
  ensure_directories

  if [[ ! -f "$CEF_ARCHIVE_PATH" ]]; then
    echo "Downloading CEF ${CEF_VERSION} for ${CEF_PLATFORM}"
    curl -fsSL "${CEF_DOWNLOAD_URL}.sha1" -o "${CEF_ARCHIVE_PATH}.sha1"
    curl -L "${CEF_DOWNLOAD_URL}" -o "$CEF_ARCHIVE_PATH"

    local expected_sha
    local actual_sha
    expected_sha="$(tr -d '\n' < "${CEF_ARCHIVE_PATH}.sha1")"
    actual_sha="$(shasum -a 1 "$CEF_ARCHIVE_PATH" | awk '{print $1}')"
    if [[ "$expected_sha" != "$actual_sha" ]]; then
      echo "error: SHA1 mismatch for $CEF_ARCHIVE_PATH" >&2
      exit 1
    fi
  fi

  if [[ ! -d "$CEF_ROOT" ]]; then
    echo "Extracting $CEF_ARCHIVE"
    tar -xjf "$CEF_ARCHIVE_PATH" -C "$THIRD_PARTY_DIR"
  fi

  rm -f "$CURRENT_LINK"
  ln -s "$CEF_ROOT" "$CURRENT_LINK"
}

build_wrapper_library() {
  if [[ -f "$WRAPPER_LIB" ]]; then
    printf '%s\n' "$WRAPPER_LIB"
    return 0
  fi

  echo "Building libcef_dll_wrapper ($CONFIGURATION)"
  cmake \
    -S "$CURRENT_LINK" \
    -B "$WRAPPER_BUILD_DIR" \
    -G Xcode \
    -DPROJECT_ARCH="$PROJECT_ARCH" \
    -DUSE_SANDBOX=OFF

  cmake \
    --build "$WRAPPER_BUILD_DIR" \
    --config "$CONFIGURATION" \
    --target libcef_dll_wrapper

  printf '%s\n' "$WRAPPER_LIB"
}

case "$COMMAND" in
  ensure)
    download_cef_distribution
    build_wrapper_library
    ;;
  update)
    rm -rf "$CEF_ROOT" "$WRAPPER_BUILD_DIR"
    download_cef_distribution
    build_wrapper_library
    ;;
  root)
    download_cef_distribution
    printf '%s\n' "$CURRENT_LINK"
    ;;
  wrapper)
    download_cef_distribution
    build_wrapper_library
    ;;
  version)
    printf '%s\n' "$CEF_VERSION"
    ;;
  help|--help|-h)
    cat <<'EOF'
Usage:
  ./script/chromium.sh ensure [Debug|Release]
  ./script/chromium.sh update [Debug|Release]
  ./script/chromium.sh root
  ./script/chromium.sh wrapper [Debug|Release]
  ./script/chromium.sh version

Environment:
  CEF_VERSION=<official-cef-version>
    Example:
    CEF_VERSION=141.0.5+gfe26daa+chromium-141.0.7390.55 ./script/chromium.sh update Debug
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
