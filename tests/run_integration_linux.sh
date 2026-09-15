#!/bin/sh
# Phase 1 Linux integration/shutdown wrapper.
#
# 1. builds gzscript,
# 2. launches Godot headlessly,
# 3. executes the relevant .zig scripts,
# 4. exits Godot,
# 5. preserves stdout/stderr,
# 6. propagates the exact process exit code.
#
# Never hides crashes with `|| true`. Prints `Godot exit code: N` always.
#
# Debugging notes (Phase 1):
# - Reproduce under gdb: gdb --args godot --headless --path . \
#     --script tests/lifecycle/shutdown_runner.gd
#   then `run`, and on SIGABRT: `bt` + `thread apply all bt`.
# - ASan/UBSan: rebuild the extension objects with
#   -fsanitize=address,undefined -fno-omit-frame-pointer (compile AND link),
#   then run Godot with the sanitizer runtime preloaded, e.g.
#   LD_PRELOAD=$(gcc -print-file-name=libasan.so) godot ...
#   and execute the lifecycle fixture above.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

BUILD_MODE=${BUILD_MODE:-Debug}
TIMEOUT_SECS=${TIMEOUT_SECS:-300}
# Space-separated list of extra Godot invocations is intentionally fixed: every
# run below must surface its own exit code.

zig_executable=$(command -v zig)
zls_executable=$(command -v zls || true)
godot_executable=$(command -v godot)
timeout_bin=$(command -v timeout || command -v gtimeout || true)

log_dir="$REPO_ROOT/.godot/gzscript/logs"
mkdir -p "$log_dir"

printf '[RUN] Build %s extension\n' "$BUILD_MODE"
zig build --prefix . "-Doptimize=$BUILD_MODE"

rm -rf .godot/gzscript/compiler_tree_control .godot/gzscript/compiler_tree

run_godot() {
  # $1 = log name, remaining args forwarded to godot.
  log_name=$1
  shift
  log_file="$log_dir/$log_name.log"
  printf '[RUN] godot %s (log: %s)\n' "$*" "$log_file"
  status=0
  # timeout(1) reports 124 on hang so hangs are distinguishable from crashes.
  if [ -n "$timeout_bin" ]; then
    env PATH=/usr/bin:/bin \
      GZSCRIPT_ZIG_PATH="$zig_executable" \
      GZSCRIPT_ZLS_PATH="$zls_executable" \
      "$timeout_bin" "${TIMEOUT_SECS}s" \
      "$godot_executable" --headless --path . "$@" >"$log_file" 2>&1 || status=$?
  else
    env PATH=/usr/bin:/bin \
      GZSCRIPT_ZIG_PATH="$zig_executable" \
      GZSCRIPT_ZLS_PATH="$zls_executable" \
      "$godot_executable" --headless --path . "$@" >"$log_file" 2>&1 || status=$?
  fi
  cat "$log_file"
  printf 'Godot exit code: %s\n' "$status"
  case "$status" in
    0) printf '[PASS] %s\n' "$log_name" ;;
    124) printf '[FAIL] %s: timeout/hang after %ss\n' "$log_name" "$TIMEOUT_SECS" >&2; return "$status" ;;
    134) printf '[FAIL] %s: SIGABRT (exit 134)\n' "$log_name" >&2; return "$status" ;;
    139) printf '[FAIL] %s: SIGSEGV (exit 139)\n' "$log_name" >&2; return "$status" ;;
    *) printf '[FAIL] %s: godot exited with %s\n' "$log_name" "$status" >&2; return "$status" ;;
  esac
}

run_godot import --import
run_godot lifecycle-script --script tests/lifecycle/shutdown_runner.gd
run_godot basic-scene

# Report orphan compiler / language-server processes owned by this run.
orphans=0
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -af "zig .*gzscript" >/dev/null 2>&1; then
    printf '[FAIL] orphan zig compiler processes remain\n' >&2
    pgrep -af "zig .*gzscript" >&2 || true
    orphans=1
  fi
  if [ -n "$zls_executable" ] && pgrep -af "[z]ls" >/dev/null 2>&1; then
    printf '[WARN] zls processes still running after suite (may be shared)\n' >&2
    pgrep -af "[z]ls" >&2 || true
  fi
fi
if [ "$orphans" -ne 0 ]; then
  exit 1
fi
printf '[PASS] Linux integration suite\n'
