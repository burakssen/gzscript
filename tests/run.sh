#!/bin/sh
set -eu

run_step() {
  label=$1
  shift
  printf '[RUN] %s\n' "$label"
  if "$@"; then
    printf '[PASS] %s\n' "$label"
  else
    status=$?
    printf '[FAIL] %s\n' "$label" >&2
    return "$status"
  fi
}

expect_diagnostics() {
  printf '[EXPECT] %s\n' "$1"
}

run_step "Build debug extension and compiler" zig build --prefix . -Doptimize=Debug
run_step "Run Zig unit tests" zig build test
run_step "Check Zig formatting" zig fmt --check build.zig tools addons/gzscript/zig/*.zig examples/basic/scripts tests

zig_executable=$(command -v zig)
zls_executable=$(command -v zls || true)
godot_executable=$(command -v godot)
rm -rf .godot/gzscript

run_godot() {
  env PATH=/usr/bin:/bin GZSCRIPT_ZIG_PATH="$zig_executable" \
    GZSCRIPT_ZLS_PATH="$zls_executable" \
    "$godot_executable" --headless --path . "$@"
}

run_step "Import Godot project" run_godot --import
run_step "Run basic integration scene" run_godot
run_step "Validate live bindings and ABI" run_godot --script tests/live_bindings_runner.gd
expect_diagnostics "Save tests compile intentionally invalid Zig source"
run_step "Validate asynchronous saves" run_godot --script tests/save_runner.gd
expect_diagnostics "Cache tests reject worker compilation and intentionally corrupt modules"
run_step "Validate module cache and reloads" run_godot --script tests/cache_runner.gd
run_step "Validate compilation identity races" run_godot --script tests/compiler_race_runner.gd
run_step "Validate cross-process compiler locking" run_godot --script tests/compiler_lock_runner.gd
run_step "Validate crash-atomic resource saves" run_godot --script tests/save_atomic_runner.gd
validate_compiler_tree_cleanup() {
  control=.godot/gzscript/compiler_tree_control
  fixture=.godot/gzscript/compiler_tree
  child_pid=
  cleanup_compiler_tree() {
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
      child_command=$(ps -p "$child_pid" -o command= 2>/dev/null || true)
      case "$child_command" in
        *"sleep 30"*) kill -9 "$child_pid" 2>/dev/null || true ;;
      esac
    fi
    rm -rf "$control" "$fixture"
  }
  rm -rf "$control" "$fixture"
  trap cleanup_compiler_tree EXIT HUP INT TERM
  if run_godot --script tests/compiler_tree_runner.gd; then
    :
  else
    status=$?
    return "$status"
  fi
  child_pid=$(cat "$control/child_pid")
  sleep 1
  if kill -0 "$child_pid" 2>/dev/null; then
    printf '%s\n' "compiler descendant $child_pid survived manager shutdown" >&2
    return 1
  fi
  cleanup_compiler_tree
  trap - EXIT HUP INT TERM
}
run_step "Validate compiler process-tree cleanup" validate_compiler_tree_cleanup
expect_diagnostics "Compiler output tests intentionally emit oversized diagnostics"
run_step "Validate compiler output limits" run_godot --script tests/compiler_output_runner.gd
expect_diagnostics "Compiler version tests intentionally select an incompatible Zig"
run_step "Validate compiler version enforcement" run_godot --script tests/compiler_version_runner.gd
expect_diagnostics "Failure tests compile intentionally invalid Zig source and ABI metadata"
run_step "Validate compilation failure handling" run_godot --script tests/failure_runner.gd
expect_diagnostics "Threaded Zig resource loading is intentionally rejected"
run_step "Validate threaded-load rejection" run_godot --script tests/threaded_load_runner.gd
cleanup_editor_fixture() {
  rm -f editor_test.zig editor_test.zig.uid editor_test.tscn
}
trap cleanup_editor_fixture EXIT
printf '[RUN] Validate editor language integration\n'
if editor_output=$(run_godot --editor --script tests/language_runner.gd 2>&1); then
  :
else
  status=$?
  printf '%s\n' "$editor_output"
  printf '[FAIL] Validate editor language integration\n' >&2
  exit "$status"
fi
cleanup_editor_fixture
trap - EXIT
case "$editor_output" in
  *"Required virtual method"* | *"delimiter must start with a symbol"* | *"auto brace completion open key must be a symbol"* | *'!ret.has("force")'* | *'!ret.has("call_hint")'* | *'!ret.has("type")'*)
    printf '%s\n' "$editor_output"
    printf '[FAIL] Validate editor language integration\n' >&2
    exit 1
    ;;
esac
case "$editor_output" in
  *"GZSCRIPT_LANGUAGE_OK"*)
    printf '%s\n' "GZSCRIPT_LANGUAGE_OK"
    printf '[PASS] Validate editor language integration\n'
    ;;
  *)
    printf '%s\n' "$editor_output"
    printf '[FAIL] Validate editor language integration\n' >&2
    exit 1
    ;;
esac
