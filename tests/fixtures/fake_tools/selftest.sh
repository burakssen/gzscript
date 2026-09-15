#!/bin/sh
# Contract tests for the fake compiler fixtures (fast, no Godot/Zig).
# Failing here means Godot tests built on these fakes would be meaningless.
set -eu
unset CDPATH
FIXTURES=$(cd -- "$(dirname -- "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gzscript-fakes-XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

[ "$("$FIXTURES/compiler_success.sh" version)" = "0.16.0" ] || fail "success version"
"$FIXTURES/compiler_success.sh" build-lib "-femit-bin=$TMP/out.so" >/dev/null 2>&1 || fail "success exit"
[ "$(cat "$TMP/out.so")" = "fake-module" ] || fail "success emits marker binary"

if "$FIXTURES/compiler_fail.sh" build-lib "-femit-bin=$TMP/nope.so" 2>"$TMP/err.txt"; then
  fail "fail exit"
fi
grep -q "error" "$TMP/err.txt" || fail "fail stderr"

if [ -n "$TIMEOUT_BIN" ]; then
  status=0
  "$TIMEOUT_BIN" 2s "$FIXTURES/compiler_hang.sh" build-lib >/dev/null 2>&1 || status=$?
  [ "$status" -eq 124 ] || fail "hang must time out with 124, got $status"
else
  printf '[SKIP] hang contract (no timeout binary)\n'
fi

"$FIXTURES/compiler_spawn_child.sh" build-lib "-femit-bin=$TMP/child.so" >/dev/null 2>&1 || fail "spawn exit"
child=$(pgrep -f "sleep 30" | head -n 1 || true)
[ -n "$child" ] || fail "spawn_child left no descendant"
kill -9 "$child" 2>/dev/null || true

if "$FIXTURES/compiler_large_output.sh" build-lib 2>"$TMP/big.txt"; then
  fail "large output exit"
fi
bytes=$(wc -c <"$TMP/big.txt" | tr -d ' ')
[ "$bytes" -gt 65536 ] || fail "large output too small: $bytes"

printf '[PASS] fake compiler fixtures\n'
