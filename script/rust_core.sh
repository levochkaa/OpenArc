#!/usr/bin/env bash
# Builds openarc-core, the Rust core of every OpenArc app (docs/rust-core.md), as a static library for one
# Apple platform, and keeps its checked-in Swift bindings in Sources/Core/Generated current.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Core"
OUTPUT_DIR="$ROOT_DIR/.build/rust-core"
BINDINGS_DIR="$ROOT_DIR/Sources/Core/Generated"
LIBRARY_NAME="libopenarc_core.a"

usage() {
  cat <<'EOF'
Usage: script/rust_core.sh ACTION [--platform NAME]

Actions:
  xcode       Build for Xcode's PLATFORM_NAME and refresh the bindings. Xcode's "Build Rust Core" phase runs it.
  build       Build the library for --platform (macosx, iphoneos, iphonesimulator; default macosx).
  bindings    Build for macOS and rewrite the Swift bindings.
  check       Fail when the checked-in bindings differ from the Rust sources.
  test        Run the Rust tests of the core and the sync protocol.
  credits     Rewrite the Rust crates section of Sources/Browser/Resources/Credits.html.

The library lands in .build/rust-core/PLATFORM/libopenarc_core.a.
EOF
}

if ! command -v cargo >/dev/null 2>&1 && [[ -x /opt/homebrew/opt/rustup/bin/cargo ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: openarc-core needs Rust; install it with rustup (https://rustup.rs)." >&2
  exit 1
fi

rust_target() {
  case "$1" in
    macosx) echo aarch64-apple-darwin ;;
    iphoneos) echo aarch64-apple-ios ;;
    iphonesimulator) echo aarch64-apple-ios-sim ;;
    *)
      echo "error: unsupported platform '$1'" >&2
      exit 2
      ;;
  esac
}

# Cargo runs without Xcode's environment: SDKROOT for an iOS SDK would link the host's build scripts against it.
run_cargo() {
  local environment=(
    "HOME=$HOME"
    "PATH=$PATH"
    "TMPDIR=${TMPDIR:-/tmp}"
    "CARGO_TARGET_DIR=$OUTPUT_DIR/target"
    "MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}"
    "IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
  )
  local name
  for name in DEVELOPER_DIR CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN USER; do
    if [[ -n "${!name:-}" ]]; then
      environment+=("$name=${!name}")
    fi
  done
  (cd "$CORE_DIR" && env -i "${environment[@]}" cargo "$@")
}

# Replaces a file only when its contents change, so Xcode relinks or recompiles only for real changes.
install_if_changed() {
  local source="$1" destination="$2"
  if cmp -s "$source" "$destination"; then
    return
  fi
  mkdir -p "$(dirname "$destination")"
  local staged
  staged="$(mktemp "$destination.XXXXXX")"
  cp "$source" "$staged"
  chmod 644 "$staged"
  mv -f "$staged" "$destination"
}

build_library() {
  local platform="$1" target
  target="$(rust_target "$platform")"
  if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
    rustup target add "$target" >&2
  fi
  run_cargo build --quiet --locked --release -p openarc-core --target "$target" >&2
  install_if_changed "$OUTPUT_DIR/target/$target/release/$LIBRARY_NAME" "$OUTPUT_DIR/$platform/$LIBRARY_NAME"
}

# Writes the bindings of the library for platform $1 to $2. Every platform has the same bindings.
generate_bindings() {
  local platform="$1" destination="$2"
  run_cargo run --quiet --locked -p uniffi-bindgen -- generate \
    --library "$OUTPUT_DIR/$platform/$LIBRARY_NAME" --language swift --out-dir "$destination" >&2
  mv "$destination/openarc_coreFFI.modulemap" "$destination/module.modulemap"
}

refresh_bindings() {
  local platform="$1" generated file
  generated="$(mktemp -d)"
  generate_bindings "$platform" "$generated"
  for file in "$generated"/*; do
    install_if_changed "$file" "$BINDINGS_DIR/$(basename "$file")"
  done
  rm -rf "$generated"
}

action="${1:-}"
shift || true
platform="macosx"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      platform="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$action" in
  xcode)
    platform="${PLATFORM_NAME:?Xcode sets PLATFORM_NAME}"
    build_library "$platform"
    refresh_bindings "$platform"
    ;;
  build)
    build_library "$platform"
    ;;
  bindings)
    build_library macosx
    refresh_bindings macosx
    ;;
  check)
    build_library macosx
    generated="$(mktemp -d)"
    generate_bindings macosx "$generated"
    if ! diff -r "$generated" "$BINDINGS_DIR" >/dev/null; then
      rm -rf "$generated"
      echo "error: Sources/Core/Generated is stale; run script/rust_core.sh bindings" >&2
      exit 1
    fi
    rm -rf "$generated"
    echo "Rust core bindings are current"
    ;;
  test)
    run_cargo test --quiet --locked --workspace
    ;;
  credits)
    python3 "$ROOT_DIR/script/rust_core_credits.py"
    ;;
  -h|--help|"")
    usage
    [[ -n "$action" ]] || exit 2
    ;;
  *)
    echo "error: unknown action $action" >&2
    usage >&2
    exit 2
    ;;
esac
