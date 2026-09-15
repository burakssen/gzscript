#!/bin/sh
# Fake Zig compiler: deterministic compilation failure.
set -eu
if [ "${1:-}" = "version" ]; then
  printf '0.16.0\n'
  exit 0
fi
echo "fake_main.zig:1:16: error: expected type expression, found '{'" >&2
exit 1
