#!/bin/sh
# Phase 1 Linux integration/shutdown wrapper.
#
# Thin delegate over the test dispatcher (tests/run.sh): one harness, one
# set of exit-code semantics, no divergent logic.
#
# Never hides crashes with `|| true`. The dispatcher prints decoded Godot
# exit codes per test (0 ok, 124 timeout, 134 SIGABRT, 139 SIGSEGV).
#
# Debugging notes (Phase 1):
# - Reproduce under gdb: gdb --args godot --headless --path . \
#     --script tests/lifecycle/shutdown_runner.gd
#   then `run`, and on SIGABRT: `bt` + `thread apply all bt`.
# - ASan/UBSan: rebuild with -Dsanitize=address,undefined (see
#   docs/testing.md), preload the runtimes with LD_PRELOAD, then run the
#   lifecycle group below.
set -eu
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

status=0
sh tests/run.sh build lifecycle integration || status=$?
printf 'run_integration_linux exit code: %s\n' "$status"

# Report orphan compiler processes owned by this run.
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -f "zig .*gzscript" >/dev/null 2>&1; then
    printf '[FAIL] orphan zig compiler processes remain\n' >&2
    pgrep -af "zig .*gzscript" >&2 || true
    status=1
  fi
fi
exit "$status"
