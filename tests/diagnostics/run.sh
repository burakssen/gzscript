#!/bin/sh
# Engine-independent diagnostics unit tests (no Godot, Zig compiler, or ZLS).
# Builds each test with the Zig C++ driver (portable: Linux/macOS/Windows)
# and runs them with per-test timeouts. Target: the whole group in <5s.
#
# Usage: sh tests/diagnostics/run.sh [test ...]
# Env: ZIG_BIN override, GZSCRIPT_TSAN=1 for ThreadSanitizer (Linux),
#   GZSCRIPT_KEEP_TEST_ARTIFACTS=1 to retain the build dir.
set -eu
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/scripts/common.sh"

gz_load_config
gz_discover_tools

ALL_TESTS="model store generations paths snapshots concurrency"

if [ $# -gt 0 ]; then
  WANT="$*"
else
  WANT=$ALL_TESTS
fi

if [ -z "${ZIG_BIN_RESOLVED:-}" ]; then
  printf '[FAIL] diagnostics: zig binary not found (set ZIG_BIN)\n' >&2
  exit 2
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gzscript-diagtest-XXXXXX")
if [ "${GZSCRIPT_KEEP_TEST_ARTIFACTS:-0}" = "1" ]; then
  printf 'keeping diagnostics build dir: %s\n' "$BUILD_DIR"
fi

CXX_FLAGS="-std=c++17 -fno-exceptions -Wall -Wextra -I$REPO_ROOT/src"
if [ "${GZSCRIPT_TSAN:-0}" = "1" ]; then
  CXX_FLAGS="$CXX_FLAGS -fsanitize=thread -fno-omit-frame-pointer -g"
fi

PASS_COUNT=0
FAIL_COUNT=0
for test_name in $WANT; do
  case " $ALL_TESTS " in
    *" $test_name "*) ;;
    *) printf '[FAIL] unknown diagnostics test: %s\n' "$test_name" >&2; exit 2 ;;
  esac
  printf '[RUN] diagnostics/%s\n' "$test_name"
  if ! "$ZIG_BIN_RESOLVED" c++ $CXX_FLAGS \
    "$REPO_ROOT/src/diagnostics/gz_diagnostic.cpp" \
    "$REPO_ROOT/src/diagnostics/gz_diagnostic_path.cpp" \
    "$REPO_ROOT/src/diagnostics/gz_diagnostic_store.cpp" \
    "$REPO_ROOT/tests/diagnostics/test_$test_name.cpp" \
    -o "$BUILD_DIR/test_$test_name" >"$BUILD_DIR/$test_name-build.log" 2>&1; then
    printf '[FAIL] diagnostics/%s: compilation failed\n' "$test_name" >&2
    cat "$BUILD_DIR/$test_name-build.log" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  status=0
  if [ -n "${TIMEOUT_BIN_RESOLVED:-}" ]; then
    "$TIMEOUT_BIN_RESOLVED" 60s "$BUILD_DIR/test_$test_name" || status=$?
  else
    "$BUILD_DIR/test_$test_name" || status=$?
  fi
  if [ "$status" -ne 0 ]; then
    printf '[FAIL] diagnostics/%s: %s\n' "$test_name" "$(gz_decode_exit "$status")" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    printf '[PASS] diagnostics/%s\n' "$test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
done

printf '\ngzscript diagnostics summary\nPassed: %s\nFailed: %s\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "${GZSCRIPT_KEEP_TEST_ARTIFACTS:-0}" != "1" ]; then
  rm -rf "$BUILD_DIR"
fi
[ "$FAIL_COUNT" -eq 0 ]
