#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/ThirdParty/cef"
SOURCE_ROOT="$THIRD_PARTY_DIR/source"
DEPOT_TOOLS_DIR="$THIRD_PARTY_DIR/depot_tools"
AUTOMATE_DIR="$THIRD_PARTY_DIR/automate"
AUTOMATE_SCRIPT="$AUTOMATE_DIR/automate-git.py"
EXPORT_ROOT="$THIRD_PARTY_DIR/export"
EXPORT_VERSION_HEADER="$EXPORT_ROOT/include/cef_version.h"
CHROMIUM_CHECKOUT_ROOT="$SOURCE_ROOT/chromium"
CHROMIUM_SRC="$SOURCE_ROOT/chromium/src"
CEF_SRC="$CHROMIUM_SRC/cef"
BINARY_DISTRIB_DIR="$CEF_SRC/binary_distrib"
CHROMIUM_SRC_OVERRIDES="$ROOT_DIR/Chromium/chromium_src"
CHROMIUM_FORK_MARKER=".thebrowser-chromium-fork"
FALLBACK_CEF_CHECKOUT="0d9d52a65c74c729e568ebf8506141a1e754eaeb"
FALLBACK_CHROMIUM_CHECKOUT="refs/tags/148.0.7778.180"
DEFAULT_CEF_BRANCH="7778"

export_cef_commit_hash() {
  if [[ ! -f "$EXPORT_VERSION_HEADER" ]]; then
    return
  fi

  sed -n 's/^#define CEF_COMMIT_HASH "\([^"]*\)".*/\1/p' \
    "$EXPORT_VERSION_HEADER" \
    | head -n 1
}

export_chromium_checkout() {
  if [[ ! -f "$EXPORT_VERSION_HEADER" ]]; then
    return
  fi

  local major
  local minor
  local build
  local patch
  major="$(sed -n 's/^#define CHROME_VERSION_MAJOR \([0-9][0-9]*\).*/\1/p' "$EXPORT_VERSION_HEADER" | head -n 1)"
  minor="$(sed -n 's/^#define CHROME_VERSION_MINOR \([0-9][0-9]*\).*/\1/p' "$EXPORT_VERSION_HEADER" | head -n 1)"
  build="$(sed -n 's/^#define CHROME_VERSION_BUILD \([0-9][0-9]*\).*/\1/p' "$EXPORT_VERSION_HEADER" | head -n 1)"
  patch="$(sed -n 's/^#define CHROME_VERSION_PATCH \([0-9][0-9]*\).*/\1/p' "$EXPORT_VERSION_HEADER" | head -n 1)"

  if [[ -n "$major" && -n "$minor" && -n "$build" && -n "$patch" ]]; then
    printf 'refs/tags/%s.%s.%s.%s\n' "$major" "$minor" "$build" "$patch"
  fi
}

EXPLICIT_CEF_BRANCH="${CEF_BRANCH+x}"
EXPLICIT_CHROMIUM_CHECKOUT="${THEBROWSER_CHROMIUM_CHECKOUT+x}"
CEF_BRANCH="${CEF_BRANCH:-$DEFAULT_CEF_BRANCH}"
DEFAULT_CEF_CHECKOUT="$(export_cef_commit_hash)"
DEFAULT_CEF_CHECKOUT="${DEFAULT_CEF_CHECKOUT:-$FALLBACK_CEF_CHECKOUT}"
DEFAULT_CHROMIUM_CHECKOUT="$(export_chromium_checkout)"
DEFAULT_CHROMIUM_CHECKOUT="${DEFAULT_CHROMIUM_CHECKOUT:-$FALLBACK_CHROMIUM_CHECKOUT}"
CEF_CHECKOUT="${THEBROWSER_CEF_CHECKOUT:-}"
if [[ -z "$CEF_CHECKOUT" && -z "$EXPLICIT_CEF_BRANCH" ]]; then
  CEF_CHECKOUT="$DEFAULT_CEF_CHECKOUT"
fi
CHROMIUM_CHECKOUT="${THEBROWSER_CHROMIUM_CHECKOUT:-}"
if [[ -z "$CHROMIUM_CHECKOUT" && -z "$EXPLICIT_CEF_BRANCH" ]]; then
  CHROMIUM_CHECKOUT="$DEFAULT_CHROMIUM_CHECKOUT"
fi
GCLIENT_JOBS="${GCLIENT_JOBS:-4}"

case "$(uname -m)" in
  arm64)
    PROJECT_ARCH="arm64"
    CEF_ARCH_ARG="--arm64-build"
    CEF_PLATFORM_SUFFIX="macosarm64"
    ;;
  x86_64)
    PROJECT_ARCH="x64"
    CEF_ARCH_ARG="--x64-build"
    CEF_PLATFORM_SUFFIX="macosx64"
    ;;
  *)
    echo "error: unsupported host architecture $(uname -m)" >&2
    exit 1
    ;;
esac

ensure_bootstrap_tools() {
  mkdir -p "$THIRD_PARTY_DIR" "$AUTOMATE_DIR"

  if [[ ! -d "$DEPOT_TOOLS_DIR/.git" ]]; then
    rm -rf "$DEPOT_TOOLS_DIR"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
  fi

  if [[ ! -f "$AUTOMATE_SCRIPT" ]]; then
    curl -fsSL \
      https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py \
      -o "$AUTOMATE_SCRIPT"
  fi
}

print_source_plan() {
  local cef_ref="${CEF_CHECKOUT:-$CEF_BRANCH}"
  local chromium_ref="${CHROMIUM_CHECKOUT:-CEF compatibility file}"
  echo "Using CEF checkout: $cef_ref"
  echo "Using Chromium checkout: $chromium_ref"
}

checkout_source() {
  ensure_bootstrap_tools
  mkdir -p "$SOURCE_ROOT"

  local automate_args=(
    --download-dir="$SOURCE_ROOT" \
    --depot-tools-dir="$DEPOT_TOOLS_DIR" \
    --branch="$CEF_BRANCH" \
    --force-config \
    --no-chromium-history \
    --no-distrib \
    --no-build \
    "$CEF_ARCH_ARG"
  )
  if [[ -n "$CEF_CHECKOUT" ]]; then
    automate_args+=(--checkout="$CEF_CHECKOUT")
  fi
  if [[ -n "$CHROMIUM_CHECKOUT" ]]; then
    automate_args+=(--chromium-checkout="$CHROMIUM_CHECKOUT")
  fi

  print_source_plan
  PATH="$DEPOT_TOOLS_DIR:$PATH" python3 "$AUTOMATE_SCRIPT" "${automate_args[@]}"

  if [[ -n "$EXPLICIT_CHROMIUM_CHECKOUT" ]]; then
    write_cef_chromium_compatibility "$CHROMIUM_CHECKOUT"
  fi
}

checkout_cef_source_revision() {
  if [[ ! -d "$SOURCE_ROOT/cef/.git" ]]; then
    return
  fi

  local cef_ref="${CEF_CHECKOUT:-$CEF_BRANCH}"
  (
    cd "$SOURCE_ROOT/cef"
    git reset --hard
    git clean -fd

    local current_head
    local target_commit
    current_head="$(git rev-parse HEAD)"
    target_commit="$(git rev-parse --verify --quiet "$cef_ref^{commit}" || true)"
    if [[ -n "$target_commit" && "$current_head" == "$target_commit" ]]; then
      echo "CEF checkout already at $cef_ref ($current_head); skipping fetch."
      return
    fi

    if git fetch origin "$cef_ref" --depth=1; then
      git checkout --force FETCH_HEAD
    elif [[ -n "$CEF_CHECKOUT" ]]; then
      git fetch origin "$CEF_BRANCH" --depth=200
      git checkout --force "$CEF_CHECKOUT"
    else
      exit 1
    fi
  )

  if [[ -n "$EXPLICIT_CHROMIUM_CHECKOUT" ]]; then
    write_cef_chromium_compatibility "$CHROMIUM_CHECKOUT"
  fi
}

clean_interrupted_chromium_checkout() {
  if [[ -d "$CHROMIUM_SRC/.git" && ! -d "$CEF_SRC" ]]; then
    rm -rf "$CHROMIUM_SRC"
    rm -f \
      "$CHROMIUM_CHECKOUT_ROOT/.gclient" \
      "$CHROMIUM_CHECKOUT_ROOT/.gclient_entries" \
      "$CHROMIUM_CHECKOUT_ROOT/.gclient_previous_custom_vars"
    return
  fi

  echo "error: refusing to remove Chromium checkout because CEF source exists at $CEF_SRC" >&2
  exit 1
}

chromium_compat_checkout() {
  if [[ -n "$CHROMIUM_CHECKOUT" ]]; then
    printf '%s\n' "$CHROMIUM_CHECKOUT"
    return
  fi

  sed -n "s/.*'chromium_checkout': '\\([^']*\\)'.*/\\1/p" \
    "$SOURCE_ROOT/cef/CHROMIUM_BUILD_COMPATIBILITY.txt" \
    | head -n 1
}

chromium_compat_version() {
  local checkout="$1"
  case "$checkout" in
    refs/tags/*|refs/heads/*)
      printf '%s\n' "${checkout##*/}"
      ;;
    *)
      printf '%s\n' "$checkout"
      ;;
  esac
}

write_cef_chromium_compatibility() {
  local chromium_checkout="$1"
  local compatibility_file="$SOURCE_ROOT/cef/CHROMIUM_BUILD_COMPATIBILITY.txt"

  if [[ ! -f "$compatibility_file" ]]; then
    return
  fi

  python3 - "$compatibility_file" "$chromium_checkout" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
checkout = sys.argv[2]
text = path.read_text()
text = re.sub(
    r"'chromium_checkout': '[^']+'",
    f"'chromium_checkout': '{checkout}'",
    text,
    count=1,
)
path.write_text(text)
PY
}

write_chromium_gclient_config() {
  local chromium_version="$1"

  mkdir -p "$CHROMIUM_CHECKOUT_ROOT"
  cat > "$CHROMIUM_CHECKOUT_ROOT/.gclient" <<EOF
solutions = [{'managed': False, 'name': 'src', 'url': 'https://chromium.googlesource.com/chromium/src.git@$chromium_version', 'custom_vars': {'checkout_pgo_profiles': False, 'source_tarball': False, 'siso_version': 'latest', }, 'custom_deps': {}, 'deps_file': 'DEPS', 'safesync_url': ''}]
EOF
  rm -f "$CHROMIUM_CHECKOUT_ROOT/.gclient_entries"
}

checkout_compatible_chromium_revision() {
  local chromium_checkout="$1"

  if [[ ! -d "$CHROMIUM_SRC/.git" ]]; then
    return
  fi

  remove_path_if_exists "$CEF_SRC"
  remove_path_if_exists "$CHROMIUM_CHECKOUT_ROOT/_bad_scm"

  (
    cd "$CHROMIUM_SRC"
    git reset --hard

    local current_head
    local target_commit
    current_head="$(git rev-parse HEAD)"
    target_commit="$(git rev-parse --verify --quiet "$chromium_checkout^{commit}" || true)"
    if [[ -n "$target_commit" && "$current_head" == "$target_commit" ]]; then
      echo "Chromium checkout already at $chromium_checkout ($current_head); skipping fetch."
      return
    fi

    git fetch origin "$chromium_checkout" --no-tags --depth=1
    git checkout --force FETCH_HEAD
  )
}

remove_path_if_exists() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return
  fi

  local trash_path="${path}.delete.$$"
  rm -rf "$trash_path"
  mv "$path" "$trash_path"
  rm -rf "$trash_path"
}

remove_invalid_git_dependency_checkouts() {
  if [[ ! -d "$CHROMIUM_SRC" ]]; then
    return
  fi

  local git_dir
  local repo_dir
  while IFS= read -r git_dir; do
    repo_dir="${git_dir%/.git}"
    if [[ "$repo_dir" == "$CHROMIUM_SRC" ]]; then
      continue
    fi

    if ! git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
      rm -rf "$repo_dir"
      echo "Removed invalid git dependency checkout: ${repo_dir#"$CHROMIUM_SRC"/}"
    fi
  done < <(find "$CHROMIUM_SRC" -path "*/.git" -type d -print)
}

apply_runhooks_patch_for_checkout() {
  local patch_file="$SOURCE_ROOT/cef/patch/patches/runhooks"
  if [[ ! -f "$patch_file.patch" ]]; then
    return
  fi

  if ! python3 "$SOURCE_ROOT/cef/tools/patcher.py" \
    --patch-file "$patch_file" \
    --patch-dir "$CHROMIUM_SRC"; then
    echo "warning: failed to apply CEF runhooks.patch for $CHROMIUM_CHECKOUT; continuing with upstream Chromium hooks" >&2
  fi
}

resume_source_checkout() {
  ensure_bootstrap_tools
  checkout_cef_source_revision
  local chromium_checkout
  local chromium_version

  if [[ -z "$CHROMIUM_CHECKOUT" ]]; then
    CHROMIUM_CHECKOUT="$(chromium_compat_checkout)"
  fi
  chromium_checkout="$(chromium_compat_checkout)"
  if [[ -z "$chromium_checkout" ]]; then
    echo "error: failed to read chromium_checkout from $SOURCE_ROOT/cef/CHROMIUM_BUILD_COMPATIBILITY.txt" >&2
    exit 1
  fi

  print_source_plan
  chromium_version="$(chromium_compat_version "$chromium_checkout")"
  write_chromium_gclient_config "$chromium_version"
  checkout_compatible_chromium_revision "$chromium_checkout"
  remove_invalid_git_dependency_checkouts

  if [[ ! -d "$CHROMIUM_SRC/.git" ]]; then
    echo "error: Chromium source checkout not found at $CHROMIUM_SRC" >&2
    echo "Run ./script/chromium_source.sh checkout first." >&2
    exit 1
  fi

  (
    cd "$CHROMIUM_CHECKOUT_ROOT"
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
    gclient sync --reset --nohooks --no-history --jobs="$GCLIENT_JOBS"
  )

  apply_runhooks_patch_for_checkout

  (
    cd "$CHROMIUM_CHECKOUT_ROOT"
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
    gclient runhooks
  )

  if [[ ! -d "$CEF_SRC" ]]; then
    rsync -a --delete "$SOURCE_ROOT/cef/" "$CEF_SRC/"
  fi

  if [[ "${THEBROWSER_CEF_CLOBBER_OUT:-0}" == "1" ]]; then
    rm -rf "$CHROMIUM_SRC/out"
  fi
  mkdir -p "$CHROMIUM_SRC/out"
  printf "{\n  'branch': '%s',\n}\n" "$CEF_BRANCH" > "$CHROMIUM_SRC/out/cef.branch"
}

require_source_checkout() {
  if [[ ! -d "$CEF_SRC" ]]; then
    echo "error: CEF source checkout not found at $CEF_SRC" >&2
    echo "Run ./script/chromium_source.sh checkout first. If checkout was interrupted after Chromium src was created, run ./script/chromium_source.sh resume-checkout." >&2
    exit 1
  fi
}

chromium_backup_path_for_override() {
  local destination="$1"
  local directory
  local filename
  directory="$(dirname "$destination")"
  filename="$(basename "$destination")"

  if [[ "$filename" == *.* ]]; then
    printf '%s/%s-chromium.%s\n' "$directory" "${filename%.*}" "${filename##*.}"
  else
    printf '%s/%s-chromium\n' "$directory" "$filename"
  fi
}

apply_chromium_src_overrides() {
  require_source_checkout
  if [[ ! -d "$CHROMIUM_SRC_OVERRIDES" ]]; then
    return
  fi

  local override
  local relative_path
  local destination
  local backup
  while IFS= read -r override; do
    relative_path="${override#"$CHROMIUM_SRC_OVERRIDES"/}"
    destination="$CHROMIUM_SRC/$relative_path"
    backup="$(chromium_backup_path_for_override "$destination")"

    mkdir -p "$(dirname "$destination")"
    if [[ -f "$destination" && ! -f "$backup" ]]; then
      cp "$destination" "$backup"
    fi

    cp "$override" "$destination"
    echo "Applied chromium_src override: $relative_path"
  done < <(
    find "$CHROMIUM_SRC_OVERRIDES" \
      -type f \
      ! -name ".gitkeep" \
      -print | sort
  )
}

create_projects() {
  require_source_checkout
  local gn_defines="${THEBROWSER_CHROMIUM_GN_DEFINES:-is_component_build=true symbol_level=1}"

  (
    cd "$CEF_SRC"
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
    export GN_DEFINES="$gn_defines"
    ./cef_create_projects.sh
  )
}

build_configuration() {
  local configuration="$1"
  case "$configuration" in
    Debug|Release)
      ;;
    *)
      echo "error: unsupported configuration '$configuration' (expected Debug or Release)" >&2
      exit 2
      ;;
  esac

  require_source_checkout
  (
    cd "$CHROMIUM_SRC"
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
    autoninja -C "out/${configuration}_GN_${PROJECT_ARCH}" cef
  )
}

make_distribution() {
  local args=(
    "--ninja-build"
    "$CEF_ARCH_ARG"
    "--no-symbols"
    "--no-docs"
    "--no-archive"
  )
  local debug_only=false
  if [[ $# -eq 1 && "$1" == "Debug" ]]; then
    debug_only=true
    args+=(
      "--allow-partial"
      "--distrib-subdir-suffix=debug"
    )
  fi

  require_source_checkout
  local hidden_release_app=""
  local release_app="$CHROMIUM_SRC/out/Release_GN_${PROJECT_ARCH}/cefclient.app"
  if [[ "$debug_only" == true && -e "$release_app" ]]; then
    hidden_release_app="${release_app}.debug-distrib-hidden.$$"
    mv "$release_app" "$hidden_release_app"
  fi

  restore_hidden_release_app() {
    if [[ -n "$hidden_release_app" && -e "$hidden_release_app" ]]; then
      rm -rf "$release_app"
      mv "$hidden_release_app" "$release_app"
    fi
  }
  trap restore_hidden_release_app RETURN

  (
    cd "$CEF_SRC/tools"
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
    ./make_distrib.sh "${args[@]}"
  )
}

latest_distribution_dir() {
  local debug_only=false
  if [[ $# -eq 1 && "$1" == "Debug" ]]; then
    debug_only=true
  fi

  local latest
  if [[ "$debug_only" == true ]]; then
    latest="$(
      find "$BINARY_DISTRIB_DIR" \
        -maxdepth 1 \
        -type d \
        -name "cef_binary_*_${CEF_PLATFORM_SUFFIX}_debug" \
        -print 2>/dev/null \
        | sort \
        | tail -n 1
    )"
  else
    latest="$(
      find "$BINARY_DISTRIB_DIR" \
        -maxdepth 1 \
        -type d \
        -name "cef_binary_*_${CEF_PLATFORM_SUFFIX}" \
        -print 2>/dev/null \
        | sort \
        | tail -n 1
    )"
  fi

  if [[ -z "$latest" ]]; then
    echo "error: no CEF binary distribution found in $BINARY_DISTRIB_DIR" >&2
    echo "Run ./script/chromium_source.sh distrib after building the source checkout." >&2
    exit 1
  fi

  printf '%s\n' "$latest"
}

copy_component_libraries_to_export() {
  local export_root="$1"
  local configuration
  for configuration in Debug Release; do
    local framework_dir="$export_root/$configuration/Chromium Embedded Framework.framework"
    local build_dir="$CHROMIUM_SRC/out/${configuration}_GN_${PROJECT_ARCH}"
    if [[ ! -d "$framework_dir" || ! -d "$build_dir" ]]; then
      continue
    fi

    local copied=0
    local dylib
    while IFS= read -r -d '' dylib; do
      cp -p "$dylib" "$framework_dir/"
      copied=$((copied + 1))
    done < <(find "$build_dir" -maxdepth 1 -type f -name "lib*.dylib" -print0)

    if [[ "$copied" -gt 0 ]]; then
      echo "Copied $copied component dylibs into $configuration CEF framework export." >&2
    fi
  done
}

install_export() {
  local distribution_dir
  distribution_dir="$(latest_distribution_dir "$@")"

  local tmp_export="$EXPORT_ROOT.tmp"
  rm -rf "$tmp_export"
  mkdir -p "$tmp_export"
  rsync -a --delete "$distribution_dir/" "$tmp_export/"
  copy_component_libraries_to_export "$tmp_export"
  touch "$tmp_export/$CHROMIUM_FORK_MARKER"

  rm -rf "$EXPORT_ROOT"
  mv "$tmp_export" "$EXPORT_ROOT"
  "$ROOT_DIR/script/chromium.sh" root Debug >/dev/null
  printf '%s\n' "$EXPORT_ROOT"
}

configurations_from_args() {
  if [[ $# -eq 0 ]]; then
    printf '%s\n' Debug
    printf '%s\n' Release
    return
  fi

  printf '%s\n' "$@"
}

package_all() {
  checkout_source
  create_projects
  apply_chromium_src_overrides

  local configuration
  while IFS= read -r configuration; do
    build_configuration "$configuration"
  done < <(configurations_from_args "$@")

  make_distribution "$@"
  install_export "$@"
}

case "$COMMAND" in
  bootstrap)
    ensure_bootstrap_tools
    ;;
  checkout)
    checkout_source
    ;;
  clean-interrupted-checkout)
    clean_interrupted_chromium_checkout
    ;;
  resume-checkout)
    resume_source_checkout
    ;;
  create-projects)
    create_projects
    ;;
  apply-overrides)
    apply_chromium_src_overrides
    ;;
  build)
    while IFS= read -r configuration; do
      build_configuration "$configuration"
    done < <(configurations_from_args "$@")
    ;;
  distrib)
    make_distribution "$@"
    ;;
  export)
    install_export
    ;;
  package)
    package_all "$@"
    ;;
  root)
    printf '%s\n' "$SOURCE_ROOT"
    ;;
  help|--help|-h)
    cat <<'EOF'
Usage:
  ./script/chromium_source.sh bootstrap
  ./script/chromium_source.sh clean-interrupted-checkout
  ./script/chromium_source.sh checkout
  ./script/chromium_source.sh resume-checkout
  ./script/chromium_source.sh apply-overrides
  ./script/chromium_source.sh create-projects
  ./script/chromium_source.sh build [Debug|Release ...]
  ./script/chromium_source.sh distrib [Debug]
  ./script/chromium_source.sh export
  ./script/chromium_source.sh package [Debug|Release ...]
  ./script/chromium_source.sh root

Defaults:
  CEF checkout comes from ThirdParty/cef/export/include/cef_version.h when
  available, then falls back to 0d9d52a65c74c729e568ebf8506141a1e754eaeb.
  Chromium checkout comes from the same exported cef_version.h when available,
  then falls back to refs/tags/148.0.7778.180.
  Existing Chromium out/ build directories are preserved by default. Set
  THEBROWSER_CEF_CLOBBER_OUT=1 only when an explicit full CEF rebuild is wanted.
  GCLIENT_JOBS=4
  Source checkout: ThirdParty/cef/source
  Chromium checkout mode: --no-chromium-history
  chromium_src overrides: Chromium/chromium_src
  depot_tools: ThirdParty/cef/depot_tools
  Binary export: ThirdParty/cef/export

With no configurations, build/package uses both Debug and Release. Use package
Debug for a development-only CEF export without Release artifacts, or package
Debug Release for a full export. Set THEBROWSER_CEF_CHECKOUT and
THEBROWSER_CHROMIUM_CHECKOUT when intentionally moving the fork base. Setting
CEF_BRANCH without THEBROWSER_CEF_CHECKOUT intentionally follows that branch and
uses its compatibility file. package runs CEF patch/project generation before
applying Chromium/chromium_src overrides so local overrides do not break CEF
patch application.
EOF
    ;;
  *)
    echo "error: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
