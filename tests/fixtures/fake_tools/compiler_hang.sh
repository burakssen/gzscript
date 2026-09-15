#!/bin/sh
# Fake Zig compiler: hangs until killed (timeout/cancellation tests).
set -eu
if [ "${1:-}" = "version" ]; then
  printf '0.16.0\n'
  exit 0
fi
sleep 300
exit 0
