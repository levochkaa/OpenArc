#!/usr/bin/env bash
set -euo pipefail

# Shares resolved Swift package graphs across checkouts. A graph is keyed by the Xcode version,
# the project.yml packages section, and local package manifests, so worktrees with the same
# dependencies reuse one set of checkouts and binary artifacts instead of resolving again.
# Graphs unused for PACKAGE_GRAPH_MAX_UNUSED_DAYS are removed when a new graph is resolved.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"
PROJECT_PATH="$ROOT_DIR/TheBrowser.xcodeproj"
WORKSPACE_RESOLVED_PATH="$PROJECT_PATH/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE_GRAPH_CACHE_ROOT="$HOME/Library/Caches/TheBrowserBuild/PackageGraphs"
PACKAGE_GRAPH_MAX_UNUSED_DAYS=14

usage() {
  cat <<'EOF'
Usage:
  ./script/package_graph_cache.sh path
  ./script/package_graph_cache.sh prepare SCHEME DERIVED_DATA_PATH

path     Print the shared package graph directory for the current package inputs.
prepare  Resolve that graph once under a lock, then install its Package.resolved into the
         generated project so xcodebuild can run with automatic package resolution disabled.
EOF
}

package_graph_key() {
  {
    printf '%s\n' "thebrowser-package-graph-v1"
    xcodebuild -version
    awk '
      /^packages:[[:space:]]*$/ { capture = 1; print; next }
      capture && /^[^[:space:]#]/ { exit }
      capture { print }
    ' "$ROOT_DIR/project.yml"
    if [[ -d "$ROOT_DIR/Packages" ]]; then
      find "$ROOT_DIR/Packages" -name .build -prune -o -type f \
        \( -name Package.swift -o -name 'Package@swift-*.swift' -o -name Package.resolved \) -print |
        LC_ALL=C sort |
        while IFS= read -r file; do
          printf 'file:%s\n' "${file#"$ROOT_DIR"/}"
          cat "$file"
        done
    fi
  } | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64
}

package_graph_path() {
  printf '%s/%s\n' "$PACKAGE_GRAPH_CACHE_ROOT" "$(package_graph_key)"
}

package_graph_ready() {
  local graph_path="$1"
  local artifact_path
  [[ -f "$graph_path/.ready" && -f "$graph_path/Package.resolved" && -f "$graph_path/workspace-state.json" ]] ||
    return 1

  # workspace-state.json records absolute binary artifact paths, so a moved or damaged graph
  # resolves again instead of failing every build.
  while IFS= read -r artifact_path; do
    [[ -e "$artifact_path" ]] || return 1
  done < <(sed -nE 's/^[[:space:]]*"path" : "(.*)",?$/\1/p' "$graph_path/workspace-state.json")
}

install_workspace_resolved() {
  local graph_path="$1"
  mkdir -p "$(dirname "$WORKSPACE_RESOLVED_PATH")"
  cp "$graph_path/Package.resolved" "$WORKSPACE_RESOLVED_PATH"
  touch "$graph_path/.ready"
}

remove_unused_package_graphs() {
  local current_path="$1"
  local graph_path
  for graph_path in "$PACKAGE_GRAPH_CACHE_ROOT"/*; do
    [[ -d "$graph_path" && "$graph_path" != "$current_path" ]] || continue
    if [[ -f "$graph_path/.ready" ]]; then
      [[ -n "$(find "$graph_path/.ready" -mtime "+$PACKAGE_GRAPH_MAX_UNUSED_DAYS")" ]] || continue
    elif [[ -z "$(find "$graph_path" -maxdepth 0 -mtime +1)" ]]; then
      continue
    fi
    # Skip graphs another checkout is resolving right now.
    /usr/bin/lockf -s -k -t 0 "$graph_path.lock" rm -rf "$graph_path" || continue
    rm -f "$graph_path.lock"
    echo "Removed unused Swift package graph: $graph_path"
  done
}

prepare_package_graph() {
  local scheme="$1"
  local derived_data_path="$2"
  local graph_path
  graph_path="$(package_graph_path)"

  if package_graph_ready "$graph_path"; then
    install_workspace_resolved "$graph_path"
    echo "Using Swift package graph: $graph_path"
    return
  fi

  mkdir -p "$PACKAGE_GRAPH_CACHE_ROOT"
  exec 9>"$graph_path.lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    echo "Waiting for another checkout to resolve $graph_path"
    /usr/bin/lockf -s 9
  fi
  if package_graph_ready "$graph_path"; then
    install_workspace_resolved "$graph_path"
    echo "Using Swift package graph: $graph_path"
    return
  fi

  echo "Resolving Swift package graph: $graph_path"
  rm -rf "$graph_path"
  mkdir -p "$graph_path"
  rm -f "$WORKSPACE_RESOLVED_PATH"
  xcodebuild \
    -resolvePackageDependencies \
    -project "$PROJECT_PATH" \
    -scheme "$scheme" \
    -derivedDataPath "$derived_data_path" \
    -clonedSourcePackagesDirPath "$graph_path" \
    -packageAuthorizationProvider netrc \
    -scmProvider system \
    -skipPackagePluginValidation \
    -skipMacroValidation

  if [[ ! -f "$WORKSPACE_RESOLVED_PATH" ]]; then
    echo "error: package resolution did not create $WORKSPACE_RESOLVED_PATH" >&2
    exit 1
  fi
  cp "$WORKSPACE_RESOLVED_PATH" "$graph_path/Package.resolved"
  touch "$graph_path/.ready"
  remove_unused_package_graphs "$graph_path"
}

case "${1:-}" in
  path)
    package_graph_path
    ;;
  prepare)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    prepare_package_graph "$2" "$3"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
