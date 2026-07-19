#!/bin/sh
set -eu

uvx --from scons scons platform=macos target=template_debug arch=arm64 -j8
zig test --dep godot -Mroot=tests/zig_adapter_test.zig -Mgodot=addons/gzscript/zig/godot.zig
godot --headless --path .
godot --headless --path . --script tests/failure_runner.gd
godot --headless --path . --editor --quit
