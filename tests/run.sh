#!/bin/sh
set -eu

zig build --prefix . -Doptimize=Debug
zig build test
zig fmt --check build.zig tools addons/gzscript/zig/*.zig examples/basic/scripts tests

zig_executable=$(command -v zig)
godot_executable=$(command -v godot)
rm -rf .godot/gzscript

run_godot() {
  env PATH=/usr/bin:/bin GZSCRIPT_ZIG_PATH="$zig_executable" \
    "$godot_executable" --headless --path . "$@"
}

run_godot --import
run_godot
run_godot --script tests/live_bindings_runner.gd
run_godot --script tests/save_runner.gd
run_godot --script tests/cache_runner.gd
run_godot --script tests/failure_runner.gd
editor_output=$(run_godot --editor --script tests/language_runner.gd 2>&1)
rm -f .godot/gzscript/editor_test.zig .godot/gzscript/editor_test.zig.uid
case "$editor_output" in
  *"Required virtual method"* | *"delimiter must start with a symbol"* | *"auto brace completion open key must be a symbol"* | *'!ret.has("force")'* | *'!ret.has("call_hint")'* | *'!ret.has("type")'*)
    printf '%s\n' "$editor_output"
    exit 1
    ;;
esac
case "$editor_output" in
  *"GZSCRIPT_LANGUAGE_OK"*) printf '%s\n' "GZSCRIPT_LANGUAGE_OK" ;;
  *)
    printf '%s\n' "$editor_output"
    exit 1
    ;;
esac
