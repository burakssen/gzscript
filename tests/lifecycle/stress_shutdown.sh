#!/bin/sh
# Phase 1 stress: N consecutive lifecycle launch/shutdown cycles.
# Minimum sign-off is 100 clean runs (BUILD_MODE=Debug and ReleaseFast).
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"
ITERATIONS=${1:-100}

failures=0
i=1
while [ "$i" -le "$ITERATIONS" ]; do
  printf 'Lifecycle iteration %s/%s\n' "$i" "$ITERATIONS"
  if sh tests/lifecycle/run.sh; then
    :
  else
    status=$?
    printf '[FAIL] Lifecycle iteration %s exited with %s\n' "$i" "$status" >&2
    failures=$((failures + 1))
  fi
  # No orphan compiler processes may survive a cycle.
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "zig .*gzscript" >/dev/null 2>&1; then
    printf '[FAIL] orphan zig compiler process after iteration %s\n' "$i" >&2
    pgrep -af "zig .*gzscript" >&2 || true
    failures=$((failures + 1))
  fi
  i=$((i + 1))
done
if [ "$failures" -ne 0 ]; then
  printf '[FAIL] %s/%s lifecycle iterations failed\n' "$failures" "$ITERATIONS" >&2
  exit 1
fi
printf '[PASS] %s consecutive lifecycle iterations\n' "$ITERATIONS"
