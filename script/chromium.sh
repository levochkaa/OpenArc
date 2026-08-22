#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
CONFIGURATION="${2:-Debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"
THIRD_PARTY_DIR="$ROOT_DIR/ThirdParty/cef"
WRAPPER_BUILD_DIR="$ROOT_DIR/.build/cef-wrapper"
LOCAL_CHROMIUM_FORK_CEF_ROOT="$THIRD_PARTY_DIR/export"
CHROMIUM_FORK_CEF_ROOT="${THEBROWSER_CHROMIUM_FORK_CEF_ROOT:-$LOCAL_CHROMIUM_FORK_CEF_ROOT}"
CHROMIUM_FORK_MARKER=".thebrowser-chromium-fork"

case "$(uname -m)" in
  arm64)
    PROJECT_ARCH="arm64"
    ;;
  x86_64)
    PROJECT_ARCH="x86_64"
    ;;
  *)
    echo "error: unsupported host architecture $(uname -m)" >&2
    exit 1
    ;;
esac

CURRENT_LINK="$THIRD_PARTY_DIR/current"
WRAPPER_LIB="$WRAPPER_BUILD_DIR/libcef_dll_wrapper/$CONFIGURATION/libcef_dll_wrapper.a"
DOXYGEN_STUB="$WRAPPER_BUILD_DIR/doxygen-stub/doxygen"

ensure_directories() {
  mkdir -p "$THIRD_PARTY_DIR"
}

validate_configuration() {
  case "$CONFIGURATION" in
    Debug|Release)
      ;;
    *)
      echo "error: unsupported CONFIGURATION '$CONFIGURATION' (expected Debug or Release)" >&2
      exit 2
      ;;
  esac
}

resolved_chromium_fork_cef_root() {
  cd "$CHROMIUM_FORK_CEF_ROOT"
  pwd -P
}

require_chromium_fork_cef_export() {
  if [[ -z "$CHROMIUM_FORK_CEF_ROOT" ]]; then
    cat >&2 <<'EOF'
error: TheBrowser requires a Chromium fork CEF export.
Create the project-local export with ./script/chromium_source.sh package Debug,
or set THEBROWSER_CHROMIUM_FORK_CEF_ROOT=/path/to/thebrowser-chromium/cef-export.
Stock CEF downloads are intentionally disabled because full Chrome extension support is mandatory.
EOF
    exit 1
  fi

  if [[ ! -d "$CHROMIUM_FORK_CEF_ROOT" ]]; then
    echo "error: Chromium fork CEF export does not exist: $CHROMIUM_FORK_CEF_ROOT" >&2
    echo "Run ./script/chromium_source.sh package $CONFIGURATION to create the project-local export." >&2
    exit 1
  fi

  if [[ ! -f "$CHROMIUM_FORK_CEF_ROOT/include/cef_app.h" ]]; then
    echo "error: Chromium fork CEF export is missing include/cef_app.h: $CHROMIUM_FORK_CEF_ROOT" >&2
    exit 1
  fi

  if [[ ! -f "$CHROMIUM_FORK_CEF_ROOT/$CHROMIUM_FORK_MARKER" ]]; then
    echo "error: Chromium fork CEF export is missing $CHROMIUM_FORK_MARKER: $CHROMIUM_FORK_CEF_ROOT" >&2
    echo "The runtime must come from TheBrowser's Chromium fork, not a stock CEF bundle." >&2
    exit 1
  fi

  local required_path
  for required_path in \
    "CMakeLists.txt" \
    "CREDITS.html" \
    "$CONFIGURATION/Chromium Embedded Framework.framework" \
    "libcef_dll/CMakeLists.txt"; do
    if [[ ! -e "$CHROMIUM_FORK_CEF_ROOT/$required_path" ]]; then
      echo "error: Chromium fork CEF export is missing $required_path: $CHROMIUM_FORK_CEF_ROOT" >&2
      exit 1
    fi
  done
}

use_chromium_fork_cef_export() {
  require_chromium_fork_cef_export
  local resolved_root
  resolved_root="$(resolved_chromium_fork_cef_root)"

  ensure_directories
  local current_target
  current_target="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
  if [[ "$current_target" != "$resolved_root" ]]; then
    rm -rf "$WRAPPER_BUILD_DIR"
  fi
  rm -f "$CURRENT_LINK"
  ln -s "$resolved_root" "$CURRENT_LINK"
  echo "Using TheBrowser Chromium fork CEF export: $resolved_root"
}

build_wrapper_library() {
  if [[ -f "$WRAPPER_LIB" ]]; then
    printf '%s\n' "$WRAPPER_LIB"
    return 0
  fi

  ensure_doxygen_stub
  echo "Building libcef_dll_wrapper ($CONFIGURATION)"
  cmake \
    -S "$CURRENT_LINK" \
    -B "$WRAPPER_BUILD_DIR" \
    -G Xcode \
    -DPROJECT_ARCH="$PROJECT_ARCH" \
    -DDOXYGEN_EXECUTABLE="$DOXYGEN_STUB" \
    -DUSE_SANDBOX=OFF

  cmake \
    --build "$WRAPPER_BUILD_DIR" \
    --config "$CONFIGURATION" \
    --target libcef_dll_wrapper \
    -- -quiet OTHER_LIBTOOLFLAGS=-no_warning_for_no_symbols

  printf '%s\n' "$WRAPPER_LIB"
}

ensure_doxygen_stub() {
  mkdir -p "$(dirname "$DOXYGEN_STUB")"
  cat > "$DOXYGEN_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  echo "1.9.8"
  exit 0
fi

output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g)
      shift
      output="${1:-}"
      ;;
  esac
  shift || true
done

if [[ -n "$output" ]]; then
  cat > "$output" <<'DOXYFILE'
PROJECT_NAME = "CEF"
OUTPUT_DIRECTORY = docs
GENERATE_HTML = YES
GENERATE_LATEX = NO
DOXYFILE
fi
EOF
  chmod +x "$DOXYGEN_STUB"
}

case "$COMMAND" in
  ensure)
    validate_configuration
    use_chromium_fork_cef_export
    build_wrapper_library
    ;;
  update)
    validate_configuration
    rm -rf "$WRAPPER_BUILD_DIR"
    use_chromium_fork_cef_export
    build_wrapper_library
    ;;
  root)
    validate_configuration
    use_chromium_fork_cef_export
    printf '%s\n' "$CURRENT_LINK"
    ;;
  wrapper)
    validate_configuration
    use_chromium_fork_cef_export
    build_wrapper_library
    ;;
  version)
    require_chromium_fork_cef_export
    basename "$(resolved_chromium_fork_cef_root)"
    ;;
  help|--help|-h)
    cat <<'EOF'
Usage:
  ./script/chromium.sh ensure [Debug|Release]
  ./script/chromium.sh update [Debug|Release]
  ./script/chromium.sh root
  ./script/chromium.sh wrapper [Debug|Release]
  ./script/chromium.sh version

Project-local source/export workflow:
  ./script/chromium_source.sh package Debug
    Checks out CEF/Chromium under ThirdParty/cef/source, builds the fork, and
    stages a binary export under ThirdParty/cef/export.

Environment:
	  THEBROWSER_CHROMIUM_FORK_CEF_ROOT=/path/to/thebrowser-chromium/cef-export
	    Optional override. By default this script uses ThirdParty/cef/export.
	    The export must come from TheBrowser's Chromium fork and include:
	    .thebrowser-chromium-fork
	    include/cef_app.h
	    libcef_dll/CMakeLists.txt
	    Debug/Chromium Embedded Framework.framework for Debug builds
	    Release/Chromium Embedded Framework.framework for Release builds

Stock CEF downloads are intentionally unavailable.
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
