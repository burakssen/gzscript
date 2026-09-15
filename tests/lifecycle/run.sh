#!/bin/sh
# Minimal lifecycle reproduction: build -> import -> one script/instance run.
# Propagates the exact Godot exit code and prints it. No `|| true`.
set -eu
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"
BUILD_MODE=${BUILD_MODE:-Debug}
TIMEOUT_SECS=${TIMEOUT_SECS:-120}

zig build --prefix . "-Doptimize=$BUILD_MODE"

zig_executable=$(command -v zig)
zls_executable=$(command -v zls || true)
godot_executable=$(command -v godot)
# Resolve before PATH is restricted below (macOS coreutils live outside
# /usr/bin:/bin; Linux CI has /usr/bin/timeout).
timeout_bin=$(command -v timeout || command -v gtimeout || true)

run_lifecycle() {
  mode_label=$1
  abandon_value=$2
  output=
  status=0
  if [ -n "$timeout_bin" ]; then
    output=$(env PATH=/usr/bin:/bin \
      GZSCRIPT_ZIG_PATH="$zig_executable" \
      GZSCRIPT_ZLS_PATH="$zls_executable" \
      GZ_LIFECYCLE_ABANDON="$abandon_value" \
      "$timeout_bin" "${TIMEOUT_SECS}s" \
      "$godot_executable" --headless --path . \
      --script tests/lifecycle/shutdown_runner.gd 2>&1) || status=$?
  else
    output=$(env PATH=/usr/bin:/bin \
      GZSCRIPT_ZIG_PATH="$zig_executable" \
      GZSCRIPT_ZLS_PATH="$zls_executable" \
      GZ_LIFECYCLE_ABANDON="$abandon_value" \
      "$godot_executable" --headless --path . \
      --script tests/lifecycle/shutdown_runner.gd 2>&1) || status=$?
  fi
  printf '%s\n' "$output"
  printf 'Godot exit code (%s): %s\n' "$mode_label" "$status"
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  case "$output" in
    *GZSCRIPT_LIFECYCLE_OK*) return 0 ;;
    *) printf '[FAIL] lifecycle %s: success token missing\n' "$mode_label" >&2; return 1 ;;
  esac
}

failures=0
run_lifecycle "explicit-free" "" || failures=$((failures + 1))
run_lifecycle "abandon-in-tree" "1" || failures=$((failures + 1))
if [ "$failures" -ne 0 ]; then
  printf '[FAIL] lifecycle: %s mode(s) failed\n' "$failures" >&2
  exit 1
fi
printf '[PASS] lifecycle (explicit-free + abandon-in-tree)\n'
