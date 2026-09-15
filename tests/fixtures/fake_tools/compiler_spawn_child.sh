#!/bin/sh
# Fake Zig compiler: spawns a lingering child, then succeeds.
# Process-tree cleanup must reap the child too, not just this process.
set -eu
if [ "${1:-}" = "version" ]; then
  printf '0.16.0\n'
  exit 0
fi
out=""
for arg in "$@"; do
  case "$arg" in
    -femit-bin=*) out=${arg#-femit-bin=} ;;
  esac
done
sleep 30 &
printf 'fake-module' >"$out"
exit 0
