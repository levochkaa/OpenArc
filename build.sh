#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/script/sparkle_tools.sh"
PROJECT_NAME="OpenArc"
SCHEME="OpenArc"
APP_NAME="OpenArc"
HELPER_NAME="OpenArc Helper"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
IOS_SCHEME="OpenArciOS"
IOS_DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-ios"
OPENARC_BUILD_CACHE_ROOT="$HOME/Library/Caches/OpenArcBuild"
source_packages_dir=""
ios_destination="${OPENARC_IOS_DESTINATION:-}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-YES}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-7Z2WHPKU8W}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-YES}"
ALLOW_PROVISIONING_DEVICE_REGISTRATION="${ALLOW_PROVISIONING_DEVICE_REGISTRATION:-YES}"

action="build"
full_output=0
skip_build=0
refresh_chromium_artifacts=0
chromium_artifact_source="${OPENARC_CHROMIUM_ARTIFACT_SOURCE:-}"
runtime_suffix="${OPENARC_RUNTIME_SUFFIX:-}"
passthrough_args=()
passthrough_arg_count=0
test_all=0

usage() {
  cat <<'EOF'
Usage: ./build.sh [action] [options] [-- extra-xcodebuild-args...]

Actions:
  build                 Build OpenArc. This is the default action.
  test                  Build and run the test suite.
  ios-build             Build the UIKit app for iOS Simulator without launching it.
  ios-test              Run iOS tests in a dedicated UIKit test host on the specified simulator.
  run                   Stop, build, and launch this worktree's app instance.
  debug                 Stop, build, and launch this worktree under LLDB.
  logs, run-logs        Run this worktree and stream its main-process logs.
  telemetry             Run this worktree and stream its main-process telemetry.
  verify                Run this worktree and verify that its process starts.
  prepare-worktree      Link reusable Chromium, CEF, and Sparkle artifacts from the main checkout.
  status                Show this worktree's build, runtime, and Chromium artifact state.

Options:
  --configuration NAME  Build Debug or Release. Default: Debug.
  --debug               Build the Debug configuration.
  --release             Build the Release configuration.
  --full-output         Print complete xcodebuild output instead of warnings/errors only.
  --skip-build          For run/debug/logs/telemetry/verify, launch the existing app bundle.
  --all                 For test, also run the tests that need the active app (key windows, focus).
                        They take the keyboard and the front app, so run them before a pre-release
                        or when the Mac is free. Without it, the test process can never become active.
  --runtime-suffix ID   Override the stable per-worktree CEF/session identity.
                        Such an instance syncs only when OPENARC_SYNC_BASE_URL is set.
  --ios-destination DEST
                        Simulator destination, e.g. 'platform=iOS Simulator,id=UUID'.
                        Required for ios-test; ios-build defaults to a generic simulator.
  --chromium-artifact-source PATH
                        Link Chromium/CEF artifacts from PATH instead of the main checkout.
  --refresh             For prepare-worktree, replace existing local artifacts or links.
  --no-code-signing     Disable code signing for build or test.
  -h, --help            Show this help.

Worktree behavior:
  Build and test automatically prepare reusable worktree artifacts when needed.
  Codex worktree setup also runs prepare-worktree. Linked worktrees reuse the primary
  checkout's Chromium source/out, CEF export, CEF wrapper, and Sparkle tools while keeping app
  output local. All checkouts share resolved Swift package graphs and one compilation cache under
  ~/Library/Caches/OpenArcBuild, so a new worktree skips package resolution and reuses compiled
  modules.
  Each worktree uses its own .build directory, runtime cache, session storage, and scoped
  process shutdown, so running one checkout does not stop another checkout's browser.

Examples:
  ./build.sh
  ./build.sh test
  ./build.sh ios-build
  ./build.sh ios-test --ios-destination 'platform=iOS Simulator,id=SIMULATOR-UUID'
  ./build.sh run
  ./build.sh run --skip-build
  ./build.sh build --release
  ./build.sh prepare-worktree
  ./build.sh prepare-worktree --refresh
  ./build.sh status
EOF
}

case "${1:-build}" in
  build|test|ios-build|ios-test|run|debug|logs|run-logs|telemetry|verify|prepare-worktree|status)
    action="$1"
    shift
    ;;
  --logs)
    action="logs"
    shift
    ;;
  --telemetry)
    action="telemetry"
    shift
    ;;
  --verify)
    action="verify"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "error: --configuration requires a value" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --debug)
      CONFIGURATION="Debug"
      shift
      ;;
    --release)
      CONFIGURATION="Release"
      shift
      ;;
    --full-output|--verbose)
      full_output=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --all)
      test_all=1
      shift
      ;;
    --runtime-suffix)
      [[ $# -ge 2 ]] || { echo "error: --runtime-suffix requires a value" >&2; exit 2; }
      runtime_suffix="$2"
      shift 2
      ;;
    --ios-destination)
      [[ $# -ge 2 ]] || { echo "error: --ios-destination requires a value" >&2; exit 2; }
      ios_destination="$2"
      shift 2
      ;;
    --chromium-artifact-source)
      [[ $# -ge 2 ]] || { echo "error: --chromium-artifact-source requires a value" >&2; exit 2; }
      chromium_artifact_source="$2"
      shift 2
      ;;
    --refresh)
      refresh_chromium_artifacts=1
      shift
      ;;
    --no-code-signing)
      CODE_SIGNING_ALLOWED="NO"
      CODE_SIGNING_REQUIRED="NO"
      CODE_SIGN_STYLE="Manual"
      DEVELOPMENT_TEAM=""
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      passthrough_arg_count=$#
      passthrough_args+=("$@")
      break
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: unsupported configuration '$CONFIGURATION' (expected Debug or Release)" >&2
    exit 2
    ;;
esac

DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

primary_checkout_root() {
  local common_git_dir
  common_git_dir="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common_git_dir" && "$(basename "$common_git_dir")" == ".git" ]]; then
    dirname "$common_git_dir"
    return
  fi

  printf '%s\n' "$ROOT_DIR"
}

resolved_chromium_artifact_source() {
  if [[ -n "$chromium_artifact_source" ]]; then
    (cd "$chromium_artifact_source" && pwd -P)
    return
  fi

  primary_checkout_root
}

chromium_artifacts_ready() {
  local checkout_root="$1"
  local required_path
  local required_paths=(
    "ThirdParty/cef/export/.openarc-chromium-fork"
    "ThirdParty/cef/export/include/cef_app.h"
    "ThirdParty/cef/export/Debug/Chromium Embedded Framework.framework"
    "ThirdParty/cef/export/Release/Chromium Embedded Framework.framework"
  )

  for required_path in "${required_paths[@]}"; do
    if [[ ! -e "$checkout_root/$required_path" ]]; then
      return 1
    fi
  done
}

chromium_artifact_directory_ready() {
  local checkout_root="$1"
  local relative_path="$2"

  case "$relative_path" in
    ThirdParty/cef/source)
      [[ -f "$checkout_root/$relative_path/chromium/src/base/time/time.h" ]] &&
        [[ -d "$checkout_root/$relative_path/chromium/src/out/Debug_GN_arm64/gen" ]] &&
        [[ -d "$checkout_root/$relative_path/chromium/src/out/Release_GN_arm64/gen" ]]
      ;;
    ThirdParty/cef/export)
      [[ -f "$checkout_root/$relative_path/.openarc-chromium-fork" ]] &&
        [[ -f "$checkout_root/$relative_path/include/cef_app.h" ]] &&
        [[ -d "$checkout_root/$relative_path/Debug/Chromium Embedded Framework.framework" ]] &&
        [[ -d "$checkout_root/$relative_path/Release/Chromium Embedded Framework.framework" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

link_chromium_directory() {
  local source_root="$1"
  local relative_path="$2"
  local source_path="$source_root/$relative_path"
  local destination_path="$ROOT_DIR/$relative_path"

  if [[ -e "$destination_path" || -L "$destination_path" ]]; then
    if [[ "$refresh_chromium_artifacts" != "1" ]] && chromium_artifact_directory_ready "$ROOT_DIR" "$relative_path"; then
      echo "$relative_path is already ready"
      return
    fi

    if [[ "$refresh_chromium_artifacts" != "1" ]]; then
      echo "error: incomplete Chromium artifacts already exist at $destination_path" >&2
      echo "Run ./build.sh prepare-worktree --refresh to replace them explicitly." >&2
      exit 1
    fi

    if [[ -L "$destination_path" ]]; then
      rm -f "$destination_path"
    else
      rm -rf "$destination_path"
    fi
  fi

  mkdir -p "$(dirname "$destination_path")"
  echo "Linking $relative_path to $source_path"
  ln -s "$source_path" "$destination_path"
}

# The CEF wrapper depends only on the shared CEF export, so a new worktree clones the source
# checkout's libraries instead of configuring and compiling its own copy.
copy_cef_wrapper_from_source() {
  local source_root="$1"
  local current_link="ThirdParty/cef/current"
  local export_root
  local configuration
  local wrapper_path

  [[ "$source_root" != "$ROOT_DIR" ]] || return 0
  [[ ! -e "$ROOT_DIR/$current_link" && ! -L "$ROOT_DIR/$current_link" ]] || return 0
  export_root="$(cd "$ROOT_DIR/ThirdParty/cef/export" && pwd -P)"
  [[ "$(readlink "$source_root/$current_link" 2>/dev/null || true)" == "$export_root" ]] || return 0

  for configuration in Debug Release; do
    wrapper_path=".build/cef-wrapper/libcef_dll_wrapper/$configuration/libcef_dll_wrapper.a"
    [[ -f "$source_root/$wrapper_path" ]] || continue
    mkdir -p "$(dirname "$ROOT_DIR/$wrapper_path")"
    cp -c "$source_root/$wrapper_path" "$ROOT_DIR/$wrapper_path" 2>/dev/null ||
      cp "$source_root/$wrapper_path" "$ROOT_DIR/$wrapper_path"
    echo "Copied $configuration libcef_dll_wrapper from $source_root"
  done
  ln -s "$export_root" "$ROOT_DIR/$current_link"
}

prepare_worktree() {
  local source_root
  source_root="$(resolved_chromium_artifact_source)"

  if [[ "$refresh_chromium_artifacts" != "1" ]] && chromium_artifacts_ready "$ROOT_DIR"; then
    echo "Chromium/CEF artifacts are ready in $ROOT_DIR"
  else
    if [[ "$source_root" == "$ROOT_DIR" ]]; then
      echo "error: Chromium/CEF artifacts are incomplete in the primary checkout: $ROOT_DIR" >&2
      echo "Build CEF and bring it here with ./script/cef_remote_build.sh (docs/cef-build.md)." >&2
      exit 1
    fi

    if ! chromium_artifacts_ready "$source_root"; then
      echo "error: Chromium/CEF artifact source is incomplete: $source_root" >&2
      exit 1
    fi

    # The app builds from the export alone. A Chromium checkout, when the primary
    # checkout has one, is linked for ./script/chromium_source.sh.
    if chromium_artifact_directory_ready "$source_root" "ThirdParty/cef/source"; then
      link_chromium_directory "$source_root" "ThirdParty/cef/source"
    fi
    link_chromium_directory "$source_root" "ThirdParty/cef/export"

    if ! chromium_artifacts_ready "$ROOT_DIR"; then
      echo "error: linked Chromium/CEF artifacts failed validation" >&2
      exit 1
    fi

    echo "Chromium/CEF worktree links prepared successfully"
  fi
  copy_cef_wrapper_from_source "$source_root"

  if sparkle_tools_ready && [[ "$refresh_chromium_artifacts" != "1" ]]; then
    echo "Sparkle tools are ready in $SPARKLE_TOOLS_DIR"
  elif prepare_sparkle_tools_from_primary "$refresh_chromium_artifacts"; then
    :
  elif sparkle_tools_ready; then
    echo "Sparkle tools are ready in $SPARKLE_TOOLS_DIR"
  else
    echo "Sparkle tools are not cached in the primary checkout; Build will download them"
  fi
}

default_runtime_suffix() {
  local checkout_label
  local checkout_hash
  checkout_label="$(basename "$(dirname "$ROOT_DIR")" | tr -cs '[:alnum:]_.-' '-')"
  checkout_label="${checkout_label#-}"
  checkout_label="${checkout_label%-}"
  checkout_hash="$(printf '%s' "$ROOT_DIR" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-12)"
  printf 'worktree-%s-%s\n' "${checkout_label:-checkout}" "$checkout_hash"
}

if [[ -z "$runtime_suffix" ]]; then
  runtime_suffix="$(default_runtime_suffix)"
fi

filter_xcode_output() {
  if [[ "$full_output" == "1" ]]; then
    cat
    return
  fi

  sed '/warning: Metadata extraction disabled by --disable/d' | grep -En "error:|warning:" || true
}

run_with_xcode_output() {
  if [[ "$full_output" == "1" ]]; then
    "$@"
    return
  fi

  set +e
  "$@" 2>&1 | filter_xcode_output
  local command_status=${PIPESTATUS[0]}
  set -e

  if [[ "$command_status" -ne 0 ]]; then
    echo "error: command failed: $*" >&2
  fi

  return "$command_status"
}

resolve_swift_packages() {
  local scheme="$1"
  local derived_data_path="$2"
  source_packages_dir="$("$ROOT_DIR/script/package_graph_cache.sh" path)"
  run_with_xcode_output "$ROOT_DIR/script/package_graph_cache.sh" prepare "$scheme" "$derived_data_path"
}

# Builds use the shared package graph prepared by resolve_swift_packages, so xcodebuild must not
# resolve again. They also share one compilation cache across checkouts: in Debug, prefix mapping
# records the checkout path, which also holds DerivedData, as /^root in Swift and /^src in
# Objective-C++ debug info, so a new worktree reuses modules compiled in another one. LLDB needs
# `settings set target.source-map /^root <checkout> /^src <checkout>` for full-path breakpoints;
# the debug action sets it.
shared_cache_arguments() {
  SHARED_CACHE_ARGS=(
    -clonedSourcePackagesDirPath "$source_packages_dir"
    -disableAutomaticPackageResolution
  )

  # Xcode splits list settings on whitespace, so such a checkout path cannot be mapped.
  [[ "$ROOT_DIR" != *[[:space:]]* ]] || return 0
  SHARED_CACHE_ARGS+=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    "COMPILATION_CACHE_CAS_PATH=$OPENARC_BUILD_CACHE_ROOT/CompilationCache/$(xcode_build_version)"
    COMPILATION_CACHE_LIMIT_SIZE=20G
  )
  # Release keeps real paths in its debug info: dsymutil copies the Swift
  # interfaces of binary frameworks such as Sentry into the dSYM only from paths
  # that exist, and crash reports symbolicate against the checkout's sources.
  [[ "$CONFIGURATION" != "Release" ]] || return 0
  SHARED_CACHE_ARGS+=(
    SWIFT_ENABLE_PREFIX_MAPPING=YES
    SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES
    CLANG_ENABLE_PREFIX_MAPPING=YES
    CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES
    "SWIFT_OTHER_PREFIX_MAPPINGS=$ROOT_DIR=/^root"
    "CLANG_OTHER_PREFIX_MAPPINGS=$ROOT_DIR=/^root"
  )
}

xcode_build_version() {
  xcodebuild -version | awk '/^Build version / { print $3 }'
}

prepare_build_environment() {
  prepare_worktree
  source "$ROOT_DIR/script/xcode_env.sh"
  run_with_xcode_output ensure_sparkle_tools
  run_with_xcode_output "$ROOT_DIR/script/generate_xcodeproj.sh"
  resolve_swift_packages "$SCHEME" "$DERIVED_DATA_PATH"
  run_with_xcode_output "$ROOT_DIR/script/chromium.sh" ensure "$CONFIGURATION"
}

clear_staged_runtime_artifacts() {
  local frameworks_dir="$APP_BUNDLE/Contents/Frameworks"
  local resources_dir="$APP_BUNDLE/Contents/Resources"

  rm -rf \
    "$frameworks_dir/Chromium Embedded Framework.framework" \
    "$frameworks_dir/$HELPER_NAME.app" \
    "$frameworks_dir/${HELPER_NAME} (Alerts).app" \
    "$frameworks_dir/${HELPER_NAME} (GPU).app" \
    "$frameworks_dir/${HELPER_NAME} (Plugin).app" \
    "$frameworks_dir/${HELPER_NAME} (Renderer).app" \
    "$resources_dir/$HELPER_NAME.app"
}

xcodebuild_arguments() {
  XCODEBUILD_ARGS=(
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -destination "platform=macOS,arch=arm64"
    -packageAuthorizationProvider netrc
    -scmProvider system
    -skipPackagePluginValidation
    -skipMacroValidation
  )
  shared_cache_arguments
  XCODEBUILD_ARGS+=("${SHARED_CACHE_ARGS[@]}")

  if [[ "$CODE_SIGNING_ALLOWED" == "YES" && "$CODE_SIGN_STYLE" == "Automatic" ]]; then
    if [[ "$ALLOW_PROVISIONING_UPDATES" == "YES" ]]; then
      XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
    fi
    if [[ "$ALLOW_PROVISIONING_DEVICE_REGISTRATION" == "YES" ]]; then
      XCODEBUILD_ARGS+=(-allowProvisioningDeviceRegistration)
    fi
  fi

  XCODEBUILD_ARGS+=(
    "CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED"
    "CODE_SIGNING_REQUIRED=$CODE_SIGNING_REQUIRED"
    "CODE_SIGN_STYLE=$CODE_SIGN_STYLE"
  )

  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  fi

  if [[ "$passthrough_arg_count" -gt 0 ]]; then
    XCODEBUILD_ARGS+=("${passthrough_args[@]}")
  fi
}

build_app() {
  prepare_build_environment
  clear_staged_runtime_artifacts
  xcodebuild_arguments
  run_with_xcode_output xcodebuild "${XCODEBUILD_ARGS[@]}" build
  echo "$APP_NAME $CONFIGURATION build succeeded"
}

test_app() {
  prepare_build_environment
  xcodebuild_arguments
  # xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
  if [[ "$test_all" -eq 1 ]]; then
    export TEST_RUNNER_OPENARC_TESTS_FOCUS=1
  else
    unset TEST_RUNNER_OPENARC_TESTS_FOCUS
  fi
  run_with_xcode_output xcodebuild "${XCODEBUILD_ARGS[@]}" test
  echo "$APP_NAME $CONFIGURATION tests succeeded"
}

prepare_ios_build_environment() {
  source "$ROOT_DIR/script/xcode_env.sh"
  run_with_xcode_output "$ROOT_DIR/script/generate_xcodeproj.sh"
  resolve_swift_packages "$IOS_SCHEME" "$IOS_DERIVED_DATA_PATH"
}

ios_xcodebuild_arguments() {
  IOS_XCODEBUILD_ARGS=(
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj"
    -scheme "$IOS_SCHEME"
    -configuration "$CONFIGURATION"
    -derivedDataPath "$IOS_DERIVED_DATA_PATH"
    -destination "$ios_destination"
    -packageAuthorizationProvider netrc
    -scmProvider system
    -skipPackagePluginValidation
    -skipMacroValidation
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
  )
  shared_cache_arguments
  IOS_XCODEBUILD_ARGS+=("${SHARED_CACHE_ARGS[@]}")
  if [[ "$passthrough_arg_count" -gt 0 ]]; then
    IOS_XCODEBUILD_ARGS+=("${passthrough_args[@]}")
  fi
}

run_ios_action() {
  local build_action="$1"
  if [[ -z "$ios_destination" ]]; then
    if [[ "$build_action" == "test" ]]; then
      echo "error: ios-test requires --ios-destination 'platform=iOS Simulator,id=UUID'" >&2
      exit 2
    fi
    ios_destination="generic/platform=iOS Simulator"
  fi
  if [[ "$ios_destination" != "platform=iOS Simulator,"* &&
        !( "$build_action" == "build" && "$ios_destination" == "generic/platform=iOS Simulator" ) ]]; then
    echo "error: iOS actions require an iOS Simulator destination" >&2
    exit 2
  fi
  prepare_ios_build_environment
  ios_xcodebuild_arguments
  if [[ "$build_action" == "test" ]]; then
    IOS_XCODEBUILD_ARGS+=(-parallel-testing-enabled NO)
  fi
  run_with_xcode_output xcodebuild "${IOS_XCODEBUILD_ARGS[@]}" "$build_action"
  echo "$APP_NAME iOS $CONFIGURATION $build_action succeeded ($ios_destination)"
}

bundle_process_ids() {
  local process_snapshot
  process_snapshot="$(/bin/ps -axo pid=,command= 2>/dev/null)" || return 1

  while read -r pid command; do
    case "$command" in
      "$APP_BINARY"*|"$APP_BUNDLE/Contents/Frameworks/"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done <<< "$process_snapshot"
}

main_process_ids() {
  local process_snapshot
  process_snapshot="$(/bin/ps -axo pid=,command= 2>/dev/null)" || return 1

  while read -r pid command; do
    case "$command" in
      "$APP_BINARY"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done <<< "$process_snapshot"
}

stop_current_worktree_app() {
  local pids
  local pid
  local attempt=0
  if ! pids="$(bundle_process_ids)"; then
    echo "error: cannot inspect running processes for this worktree" >&2
    exit 1
  fi

  if [[ -n "$pids" ]]; then
    echo "Stopping $APP_NAME processes from $APP_BUNDLE"
    for pid in $pids; do
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
    done
  fi

  while [[ $attempt -lt 50 ]]; do
    if ! pids="$(bundle_process_ids)"; then
      echo "error: cannot inspect running processes for this worktree" >&2
      exit 1
    fi
    if [[ -z "$pids" ]]; then
      return
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done

  echo "error: failed to stop $APP_NAME processes for this worktree" >&2
  exit 1
}

require_app_bundle() {
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle not found at $APP_BUNDLE" >&2
    echo "Run ./build.sh build first or omit --skip-build." >&2
    exit 1
  fi
}

launch_app() {
  require_app_bundle
  echo "Launching $APP_BUNDLE with runtime suffix $runtime_suffix"
  /usr/bin/open -n "$APP_BUNDLE" --args "--runtime-suffix=$runtime_suffix"
}

wait_for_main_process() {
  local pid
  local attempt=0
  while [[ $attempt -lt 100 ]]; do
    if ! pid="$(main_process_ids | /usr/bin/head -n 1)"; then
      echo "error: cannot inspect running processes for this worktree" >&2
      return 1
    fi
    if [[ -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done

  return 1
}

prepare_run() {
  stop_current_worktree_app
  if [[ "$skip_build" != "1" ]]; then
    build_app
  fi
  require_app_bundle
}

run_and_stream_logs() {
  local mode="$1"
  local pid
  prepare_run
  launch_app
  if ! pid="$(wait_for_main_process)"; then
    echo "error: $APP_NAME did not start for this worktree" >&2
    exit 1
  fi

  echo "Streaming $mode for $APP_NAME pid $pid"
  /usr/bin/log stream --info --style compact --predicate "processIdentifier == $pid"
}

show_status() {
  local source_root
  local pids
  local process_status_available=1
  source_root="$(resolved_chromium_artifact_source)"
  if ! pids="$(bundle_process_ids)"; then
    pids=""
    process_status_available=0
  fi

  echo "Checkout: $ROOT_DIR"
  echo "Primary checkout: $(primary_checkout_root)"
  echo "Chromium artifact source: $source_root"
  if chromium_artifacts_ready "$ROOT_DIR"; then
    echo "Chromium/CEF artifacts: ready"
  else
    echo "Chromium/CEF artifacts: missing or incomplete"
  fi
  if sparkle_tools_ready; then
    if [[ -L "$SPARKLE_TOOLS_DIR" ]]; then
      echo "Sparkle tools: ready (shared from $(readlink "$SPARKLE_TOOLS_DIR"))"
    else
      echo "Sparkle tools: ready (local)"
    fi
  else
    echo "Sparkle tools: missing or incomplete"
  fi
  echo "Configuration: $CONFIGURATION"
  echo "DerivedData: $DERIVED_DATA_PATH"
  echo "App bundle: $APP_BUNDLE"
  echo "Runtime suffix: $runtime_suffix"
  if [[ "$process_status_available" != "1" ]]; then
    echo "Running process IDs: unavailable"
  elif [[ -n "$pids" ]]; then
    echo "Running process IDs: ${pids//$'\n'/, }"
  else
    echo "Running process IDs: none"
  fi
}

case "$action" in
  build)
    build_app
    ;;
  test)
    test_app
    ;;
  ios-build)
    run_ios_action build
    ;;
  ios-test)
    run_ios_action test
    ;;
  run)
    prepare_run
    launch_app
    ;;
  debug)
    prepare_run
    lldb -o "settings set target.source-map /^root '$ROOT_DIR' /^src '$ROOT_DIR'" \
      -- "$APP_BINARY" "--runtime-suffix=$runtime_suffix"
    ;;
  logs|run-logs|telemetry)
    run_and_stream_logs "$action"
    ;;
  verify)
    prepare_run
    launch_app
    if pid="$(wait_for_main_process)"; then
      echo "$APP_NAME started successfully for this worktree (pid $pid)"
    else
      echo "error: $APP_NAME did not start for this worktree" >&2
      exit 1
    fi
    ;;
  prepare-worktree)
    prepare_worktree
    ;;
  status)
    show_status
    ;;
esac
