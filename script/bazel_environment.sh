#!/usr/bin/env bash

configure_bazel_environment() {
  export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
  export RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS="${RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS:--B}"
  export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/.cache/bazel/thebrowser/python-pycache}"

  mkdir -p \
    "$HOME/.cache/bazel/thebrowser/disk" \
    "$HOME/.cache/bazel/thebrowser/repository" \
    "$PYTHONPYCACHEPREFIX"

  BAZEL_PYTHON_ENV_ARGS=(
    "--repo_env=PYTHONDONTWRITEBYTECODE=$PYTHONDONTWRITEBYTECODE"
    "--repo_env=RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS=$RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS"
    "--repo_env=PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
    "--host_action_env=PYTHONDONTWRITEBYTECODE=$PYTHONDONTWRITEBYTECODE"
    "--host_action_env=RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS=$RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS"
    "--host_action_env=PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
    "--action_env=PYTHONDONTWRITEBYTECODE=$PYTHONDONTWRITEBYTECODE"
    "--action_env=RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS=$RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS"
    "--action_env=PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
  )

  BAZEL_SWIFT_EXTERNAL_TOOL_ARGS=(
    # rules_swift test discovery builds these external tool dependencies. Xcode
    # 26 warns in their source, so suppress warnings only for those modules.
    "--@build_bazel_rules_swift//swift:per_module_swiftcopt=@@swift_argument_parser+//:ArgumentParser=-suppress-warnings"
    "--@build_bazel_rules_swift//swift:per_module_swiftcopt=@@rules_swift++non_module_deps+com_github_apple_swift_docc_symbolkit//:SymbolKit=-suppress-warnings"
  )

  BAZEL_BUILD_ARGS=(
    "${BAZEL_PYTHON_ENV_ARGS[@]}"
    "${BAZEL_SWIFT_EXTERNAL_TOOL_ARGS[@]}"
  )

  BAZEL_TEST_PYTHON_ENV_ARGS=(
    "${BAZEL_PYTHON_ENV_ARGS[@]}"
    "--test_env=PYTHONDONTWRITEBYTECODE=$PYTHONDONTWRITEBYTECODE"
    "--test_env=RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS=$RULES_PYTHON_ADDITIONAL_INTERPRETER_ARGS"
    "--test_env=PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
  )

  BAZEL_TEST_ARGS=(
    "${BAZEL_TEST_PYTHON_ENV_ARGS[@]}"
    "${BAZEL_SWIFT_EXTERNAL_TOOL_ARGS[@]}"
  )
}
