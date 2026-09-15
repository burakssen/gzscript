#!/bin/sh
# Fake Zig compiler: emits >128 KiB of diagnostics, then fails.
set -eu
if [ "${1:-}" = "version" ]; then
  printf '0.16.0\n'
  exit 0
fi
i=0
while [ "$i" -lt 2048 ]; do
  printf 'fake_note: diagnostic line %s padding padding padding padding\n' "$i" >&2
  i=$((i + 1))
done
exit 1
