#!/bin/sh
# Fake Zig compiler: succeeds and emits a marker "binary".
# Contract: `version` prints 0.16.0; otherwise honors -femit-bin=<path>.
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
if [ -z "$out" ]; then
  echo "fake compiler: missing -femit-bin" >&2
  exit 2
fi
printf 'fake-module' >"$out"
exit 0
