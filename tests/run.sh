#!/bin/sh
set -eu

scons platform=macos target=template_debug arch=arm64 -j8
python3 -m unittest tests/test_generate_bindings.py
zig fmt --check addons/gzscript/zig examples/basic/scripts addons/gzscript/templates tests
zig test --dep godot -Mroot=tests/zig_adapter_test.zig -Mgodot=addons/gzscript/zig/godot.zig

zig_executable=$(command -v zig)
godot_executable=$(command -v godot)
rm -rf .godot/gzscript

run_godot() {
  env PATH=/usr/bin:/bin GZSCRIPT_ZIG_PATH="$zig_executable" \
    "$godot_executable" --headless --path . "$@"
}

run_godot
run_godot --script tests/live_bindings_runner.gd
run_godot --script tests/save_runner.gd
run_godot --script tests/failure_runner.gd
run_godot --script tests/benchmark_runner.gd

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
