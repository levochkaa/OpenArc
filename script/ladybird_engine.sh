#!/usr/bin/env bash
# Builds OpenArc's Ladybird engine (Ladybird's libraries and helpers with Ladybird/engine) and brings it to this
# checkout. See docs/ladybird-engine.md.
#
#   fetch    clone Ladybird into the build root and check out Ladybird/engine/LADYBIRD_COMMIT
#   prepare  apply OpenArc's layer and patches (Ladybird/engine/apply.sh)
#   build    prepare, then build the layer and Ladybird's helpers (Meta/ladybird.py, Release, AppKit)
#   package  put "OpenArc Ladybird.framework" together in the build root's dist/
#   pull     copy the framework to ThirdParty/ladybird-engine/export of the primary checkout
#   all      fetch, build, package and pull
#   status   the build root's commit and the exported framework's version
#
# Ladybird builds natively on macOS only (its vcpkg ports and Metal code), so this runs on the Mac, at low
# priority: OPENARC_LADYBIRD_JOBS caps the compile jobs (default: half the cores).
set -euo pipefail

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/Ladybird/engine"
BUILD_ROOT="${OPENARC_LADYBIRD_ROOT:-$HOME/ladybird-engine}"
SOURCE="$BUILD_ROOT/ladybird"
BUILD_DIR="$SOURCE/Build/release"
DIST="$BUILD_ROOT/dist"
FRAMEWORK_NAME="OpenArc Ladybird"
FRAMEWORK="$FRAMEWORK_NAME.framework"
COMMIT="$(tr -d '[:space:]' < "$ENGINE_DIR/LADYBIRD_COMMIT")"
JOBS="${OPENARC_LADYBIRD_JOBS:-$(( $(sysctl -n hw.ncpu) / 2 ))}"
# The helpers Ladybird's pages run in; each goes into the framework's Helpers/.
HELPERS=(WebContent WebWorker RequestServer ImageDecoder Compositor MediaServer ProcessReaper)
OPTIONAL_HELPERS=(WasmCompiler)

primary_checkout_root() {
  local common
  common="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}
EXPORT_DIR="${OPENARC_LADYBIRD_ENGINE_EXPORT:-$(primary_checkout_root)/ThirdParty/ladybird-engine/export}"

log() { printf '==> %s\n' "$*"; }

fetch() {
  mkdir -p "$BUILD_ROOT"
  if [[ ! -d "$SOURCE/.git" ]]; then
    log "cloning Ladybird into $SOURCE"
    git clone --filter=blob:none https://github.com/LadybirdBrowser/ladybird.git "$SOURCE"
  fi
  if ! git -C "$SOURCE" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    git -C "$SOURCE" fetch origin
  fi
  if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
    log "checking out $COMMIT"
    # The layer's own files and patches go again on top.
    git -C "$SOURCE" checkout -- .
    git -C "$SOURCE" checkout --quiet "$COMMIT"
  fi
}

prepare() {
  [[ -d "$SOURCE/.git" ]] || fetch
  if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
    echo "error: $SOURCE is at $(git -C "$SOURCE" rev-parse --short HEAD), not $COMMIT; run fetch" >&2
    exit 1
  fi
  "$ENGINE_DIR/apply.sh" "$SOURCE"
}

build() {
  prepare
  log "building Ladybird and OpenArc's layer ($JOBS jobs)"
  # GNU make for vcpkg's autotools ports and rustup's cargo for LibJS's Rust parts (rust-toolchain.toml picks the
  # version); the build runs at low priority so the Mac stays usable.
  (
    cd "$SOURCE"
    export PATH="/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
    rustup install >/dev/null
    nice -n 10 ./Meta/ladybird.py build --preset Release --gui AppKit -j "$JOBS" ladybird
    nice -n 10 ./Meta/ladybird.py build --preset Release --gui AppKit -j "$JOBS" openarc_ladybird
  )
}

# The directory the build left a file in, searched in the app bundle the AppKit target makes and in lib/.
find_built() {
  local name="$1"
  find "$BUILD_DIR" -path '*/CMakeFiles' -prune -o -name "$name" -type f -print 2>/dev/null | head -n 1
}

package() {
  local app="$BUILD_DIR/bin/Ladybird.app"
  local layer="$BUILD_DIR/lib/$FRAMEWORK_NAME"
  [[ -d "$app" ]] || { echo "error: no Ladybird app at $app; run build" >&2; exit 1; }
  [[ -f "$layer" ]] || { echo "error: the layer did not build ($layer); run build" >&2; exit 1; }

  local out="$DIST/$FRAMEWORK"
  local version="$out/Versions/A"
  log "packaging $out"
  rm -rf "$out"
  mkdir -p "$version/Helpers" "$version/Libraries" "$version/Resources"

  cp "$layer" "$version/$FRAMEWORK_NAME"
  local helper
  for helper in "${HELPERS[@]}"; do
    cp "$app/Contents/MacOS/$helper" "$version/Helpers/$helper"
  done
  for helper in "${OPTIONAL_HELPERS[@]}"; do
    if [[ -f "$app/Contents/MacOS/$helper" ]]; then cp "$app/Contents/MacOS/$helper" "$version/Helpers/$helper"; fi
  done
  # WebAssembly's compiler, which WasmCompiler runs for each module. Ladybird's own app runs it from the build tree;
  # the layer points WasmCompiler at this copy.
  if [[ -f "$BUILD_DIR/bin/cranelift-compiler" ]]; then
    cp "$BUILD_DIR/bin/cranelift-compiler" "$version/Helpers/cranelift-compiler"
  fi

  # The build's binaries find their libraries through absolute rpaths into the build tree; the framework carries the
  # whole closure of @rpath libraries under the names they are loaded by.
  local search=("$BUILD_DIR/lib" "$BUILD_DIR/vcpkg_installed/arm64-osx-dynamic/lib")
  local queue=("$version/$FRAMEWORK_NAME" "$version/Helpers/"*)
  local seen=" "
  while ((${#queue[@]})); do
    local binary="${queue[0]}"
    queue=("${queue[@]:1}")
    local name
    while read -r name; do
      [[ "$seen" == *" $name "* ]] && continue
      seen+="$name "
      local dir found=""
      for dir in "${search[@]}"; do
        if [[ -e "$dir/$name" ]]; then found="$dir/$name"; break; fi
      done
      [[ -n "$found" ]] || { echo "error: $name (needed by $(basename "$binary")) is not in the build" >&2; exit 1; }
      cp -L "$found" "$version/Libraries/$name"
      chmod 755 "$version/Libraries/$name"
      queue+=("$version/Libraries/$name")
    done < <(otool -L "$binary" | sed -n 's|^[[:space:]]*@rpath/\(.*\) (compatibility .*|\1|p' | grep -v '\.framework/')
  done

  ditto "$app/Contents/Resources" "$version/Resources"
  # The app's own icon is Ladybird's, not the framework's.
  rm -f "$version/Resources/app_icon.icns" "$version/Resources/Assets.car" "$version/Resources/Info.plist"
  # Ladybird's license and those of the vcpkg libraries it carries (Credits.html points here).
  mkdir -p "$version/Resources/Licenses"
  cp "$SOURCE/LICENSE" "$version/Resources/Licenses/Ladybird.txt"
  local copyright
  for copyright in "$BUILD_DIR"/vcpkg_installed/arm64-osx-dynamic/share/*/copyright; do
    [[ -f "$copyright" ]] || continue
    cp "$copyright" "$version/Resources/Licenses/$(basename "$(dirname "$copyright")").txt"
  done
  cat > "$version/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$FRAMEWORK_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.levochkaa.OpenArc.Ladybird</string>
  <key>CFBundleName</key>
  <string>$FRAMEWORK_NAME</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${COMMIT:0:10}</string>
  <key>CFBundleVersion</key>
  <string>${COMMIT:0:10}</string>
</dict>
</plist>
PLIST

  # The framework's binary loads its libraries from Libraries/, the helpers from ../Libraries, the libraries from
  # beside themselves.
  local file
  fix_rpaths() {
    local target="$1" wanted="$2" existing
    while read -r existing; do
      if [[ -n "$existing" ]]; then install_name_tool -delete_rpath "$existing" "$target" 2>/dev/null || true; fi
    done < <(otool -l "$target" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
    install_name_tool -add_rpath "$wanted" "$target" 2>/dev/null
  }
  fix_rpaths "$version/$FRAMEWORK_NAME" "@loader_path/Libraries"
  install_name_tool -id "@rpath/$FRAMEWORK/Versions/A/$FRAMEWORK_NAME" "$version/$FRAMEWORK_NAME" 2>/dev/null
  for file in "$version/Helpers/"*; do
    fix_rpaths "$file" "@executable_path/../Libraries"
  done
  for file in "$version/Libraries/"*.dylib; do
    fix_rpaths "$file" "@loader_path"
  done

  ln -sfn A "$out/Versions/Current"
  ln -sfn "Versions/Current/$FRAMEWORK_NAME" "$out/$FRAMEWORK_NAME"
  ln -sfn Versions/Current/Resources "$out/Resources"
  ln -sfn Versions/Current/Helpers "$out/Helpers"
  ln -sfn Versions/Current/Libraries "$out/Libraries"
  printf '%s\n' "$COMMIT" > "$DIST/.ladybird-commit"

  # Ad hoc signatures, as the app build re-signs it with its own identity.
  for file in "$version/Libraries/"*.dylib; do
    codesign --force --sign - "$file" 2>/dev/null
  done
  for file in "$version/Helpers/"*; do
    if [[ "$(basename "$file")" == cranelift-compiler ]]; then
      codesign --force --sign - --options runtime "$file" 2>/dev/null
    else
      codesign --force --sign - --options runtime --entitlements "$ROOT_DIR/Support/OpenArcLadybirdHelper.entitlements" "$file" 2>/dev/null
    fi
  done
  codesign --force --sign - "$out" 2>/dev/null
  du -sh "$out"
}

pull() {
  local source="$DIST/$FRAMEWORK"
  [[ -d "$source" ]] || { echo "error: no framework at $source; run package" >&2; exit 1; }
  log "copying to $EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  rm -rf "${EXPORT_DIR:?}/$FRAMEWORK"
  ditto "$source" "$EXPORT_DIR/$FRAMEWORK"
  cp "$DIST/.ladybird-commit" "$EXPORT_DIR/.ladybird-commit"
}

status() {
  if [[ -d "$SOURCE/.git" ]]; then
    echo "build root: $SOURCE at $(git -C "$SOURCE" rev-parse --short=10 HEAD) (wanted ${COMMIT:0:10})"
  else
    echo "build root: none at $SOURCE"
  fi
  if [[ -f "$EXPORT_DIR/.ladybird-commit" ]]; then
    echo "export: $EXPORT_DIR/$FRAMEWORK from $(cut -c1-10 "$EXPORT_DIR/.ladybird-commit")"
  else
    echo "export: none at $EXPORT_DIR"
  fi
}

case "$COMMAND" in
  fetch) fetch ;;
  prepare) prepare ;;
  build) build ;;
  package) package ;;
  pull) pull ;;
  all) fetch; build; package; pull ;;
  status) status ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    [[ "$COMMAND" == "help" ]] || exit 2
    ;;
esac
