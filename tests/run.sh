#!/bin/sh
# gzscript test dispatcher.
#
# Usage:
#   ./tests/run.sh [options] [group|group/test ...]
#
# Groups: build quality unit compiler cache concurrency runtime lifecycle
#         lsp editor integration smoke stress
# Profiles: fast, full (default), stress
# Examples:
#   ./tests/run.sh fast
#   ./tests/run.sh lifecycle
#   ./tests/run.sh lifecycle/shutdown compiler/tree
#   ./tests/run.sh --no-build runtime
#   GZSCRIPT_TEST_VERBOSE=1 ./tests/run.sh lifecycle
#
# Exit codes: 0 all passed, 1 test failure (or FLAKY observed), 2 bad usage.
# Godot crashes surface with their own codes (124 timeout, 134 SIGABRT,
# 139 SIGSEGV) decoded in the output. Never hidden with `|| true`.
#
# Variable discipline: every function prefixes its temporaries (m_, t_, g_,
# e_, s_, d_) because POSIX sh has no local variables and the executors nest
# (run_one_test -> do_* -> exec_* -> ensure_imported -> do_build_import).
set -eu

unset CDPATH
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/tests/scripts/common.sh"

gz_load_config
gz_discover_tools

SKIP_BUILD=$GZSCRIPT_SKIP_BUILD

usage() {
  sed -n '2,20p' "$ROOT/tests/run.sh"
}

list_tests() {
  printf 'groups:\n  build quality unit compiler cache concurrency runtime lifecycle lsp editor integration smoke stress\n'
  printf 'profiles:\n  fast full stress\n'
  printf 'tests:\n'
  printf '  build/extension build/import\n'
  printf '  quality/format unit/zig\n'
  printf '  compiler/save compiler/tree compiler/output compiler/version compiler/failure compiler/atomic compiler/fixture-selftest\n'
  printf '  cache/reuse\n'
  printf '  concurrency/race concurrency/lock\n'
  printf '  runtime/bindings runtime/threaded\n'
  printf '  lifecycle/shutdown lifecycle/abandon\n'
  printf '  lsp/completion\n'
  printf '  editor/language\n'
  printf '  integration/basic\n'
  printf '  smoke/project\n'
  printf '  stress/lifecycle-loops\n'
}

GROUP_TIMEOUT_secs() {
  case "$1" in
    compiler) printf '%s' "$TIMEOUT_COMPILER" ;;
    cache) printf '%s' "$TIMEOUT_CACHE" ;;
    concurrency) printf '%s' "$TIMEOUT_CONCURRENCY" ;;
    runtime) printf '%s' "$TIMEOUT_RUNTIME" ;;
    lifecycle) printf '%s' "$TIMEOUT_LIFECYCLE" ;;
    lsp|editor) printf '%s' "$TIMEOUT_EDITOR" ;;
    integration) printf '%s' "$TIMEOUT_INTEGRATION" ;;
    smoke) printf '%s' "$TIMEOUT_SMOKE" ;;
    stress) printf '%s' "$TIMEOUT_STRESS" ;;
    *) printf '120' ;;
  esac
}

# --- per-invocation state (UPPERCASE: owned by main, read-only elsewhere) --
SUMMARY_FILE=""
HOME_TMP=""
RESULTS_FAILED=0
RESULTS_FLAKY=0
IMPORTED=0

setup_invocation() {
  SUMMARY_FILE=$(mktemp "${TMPDIR:-/tmp}/gzscript-summary-XXXXXX")
  HOME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gzscript-home-XXXXXX")
  mkdir -p "$HOME_TMP/home"
  # Fresh machine-readable results per invocation; stale rows from earlier
  # local runs must never pollute the current summary or JUnit output.
  rm -rf "$ROOT/test-results"
  gz_verbose "summary: $SUMMARY_FILE home: $HOME_TMP"
}

# Explicit cleanup (no EXIT trap: subshells and command substitutions must
# never trigger harness teardown). Failure keeps dirs for forensics.
cleanup_invocation() {
  if [ "$RESULTS_FAILED" -ne 0 ]; then
    gz_log "keeping harness dirs for forensics: $SUMMARY_FILE $HOME_TMP"
    return 0
  fi
  if [ "${GZSCRIPT_KEEP_TEST_ARTIFACTS:-0}" = "1" ]; then
    gz_log "keeping harness dirs: $SUMMARY_FILE $HOME_TMP"
    return 0
  fi
  rm -rf "$SUMMARY_FILE" "$HOME_TMP"
}

# --- low-level executors --------------------------------------------------
# All Godot invocations share one hermetic environment: restricted PATH,
# explicit tool paths, isolated HOME (deterministic environments).
run_godot() {
  if [ "${GZSCRIPT_TRACE:-0}" = "1" ]; then
    env PATH=/usr/bin:/bin HOME="$HOME_TMP/home" \
      GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" \
      GZSCRIPT_ZLS_PATH="$ZLS_BIN_RESOLVED" \
      "$GODOT_BIN_RESOLVED" --headless --verbose --path "$ROOT" "$@"
  else
    env PATH=/usr/bin:/bin HOME="$HOME_TMP/home" \
      GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" \
      GZSCRIPT_ZLS_PATH="$ZLS_BIN_RESOLVED" \
      "$GODOT_BIN_RESOLVED" --headless --path "$ROOT" "$@"
  fi
}

ensure_imported() {
  if [ "$IMPORTED" = "1" ]; then
    return 0
  fi
  IMPORTED=1
  do_build_import
}

# Generic Godot --script test with token + leak + orphan checks.
# exec_godot_script <group> <name> <label> <script> <token>
exec_godot_script() {
  e_group=$1
  e_name=$2
  e_label=$3
  e_script=$4
  e_token=$5
  gz_require_godot || return $?
  gz_require_zig || return $?
  ensure_imported || return $?
  e_log=$(gz_results_dir "$e_group")/$e_name.log
  mkdir -p "$(gz_results_dir "$e_group")"
  gz_log "[RUN] $e_label"
  e_output=
  e_status=0
  if e_output=$(run_godot --script "$e_script" 2>&1); then
    :
  else
    e_status=$?
  fi
  printf '%s\n' "$e_output" >"$e_log"
  printf '%s\n' "$e_output"
  e_token_ok=0
  case "$e_output" in
    *"$e_token"*) ;;
    *) e_token_ok=1 ;;
  esac
  if [ "$e_status" -ne 0 ]; then
    gz_log "[FAIL] $e_label: $(gz_decode_exit "$e_status")" >&2
    return "$e_status"
  fi
  if [ "$e_token_ok" -ne 0 ]; then
    gz_log "[FAIL] $e_label: success token '$e_token' missing" >&2
    return 1
  fi
  gz_assert_shutdown_clean "$e_log" || return 1
  gz_assert_no_orphans || return 1
  gz_log "[PASS] $e_label"
  return 0
}

# Generic shell command test. exec_shell <group> <name> <label> -- cmd...
exec_shell() {
  s_group=$1
  s_name=$2
  s_label=$3
  shift 3
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  s_log=$(gz_results_dir "$s_group")/$s_name.log
  mkdir -p "$(gz_results_dir "$s_group")"
  gz_log "[RUN] $s_label"
  s_status=0
  "$@" >"$s_log" 2>&1 || s_status=$?
  cat "$s_log"
  if [ "$s_status" -ne 0 ]; then
    gz_log "[FAIL] $s_label: $(gz_decode_exit "$s_status")" >&2
    return "$s_status"
  fi
  gz_log "[PASS] $s_label"
  return 0
}

# --- concrete tests -------------------------------------------------------
do_build_extension() {
  exec_shell build extension "Build $BUILD_MODE extension and compiler" \
    -- sh -c "cd \"$ROOT\" && zig build --prefix . -Doptimize=\"$BUILD_MODE\""
}

do_build_import() {
  gz_require_godot || return $?
  exec_shell build import "Import Godot project" \
    -- run_godot --import
}

do_quality_format() {
  exec_shell quality format "Check formatting and generators" \
    -- sh -c "cd \"$ROOT\" && zig fmt --check build.zig tools addons/gzscript/zig/*.zig examples/basic/scripts tests && zig build check-bindings"
}

do_unit_zig() {
  exec_shell unit zig "Run Zig unit tests" \
    -- sh -c "cd \"$ROOT\" && zig build test"
}

do_compiler_save() {
  gz_log "[EXPECT] Save tests compile intentionally invalid Zig source"
  exec_godot_script compiler save "Validate asynchronous saves" \
    tests/save_runner.gd GZSCRIPT_SAVE_OK
}

do_compiler_tree() {
  d_control="$ROOT/.godot/gzscript/compiler_tree_control"
  d_fixture="$ROOT/.godot/gzscript/compiler_tree"
  gz_require_godot || return $?
  gz_require_zig || return $?
  ensure_imported || return $?
  d_log=$(gz_results_dir compiler)/tree.log
  mkdir -p "$(gz_results_dir compiler)"
  gz_log "[RUN] Validate compiler process-tree cleanup"
  rm -rf "$d_control" "$d_fixture"
  d_status=0
  run_godot --script tests/compiler_tree_runner.gd >"$d_log" 2>&1 || d_status=$?
  cat "$d_log"
  if [ "$d_status" -ne 0 ]; then
    gz_log "[FAIL] Validate compiler process-tree cleanup: $(gz_decode_exit "$d_status")" >&2
    rm -rf "$d_control" "$d_fixture"
    return "$d_status"
  fi
  if [ ! -f "$d_control/child_pid" ]; then
    gz_log "[FAIL] compiler tree fixture did not record a child PID" >&2
    rm -rf "$d_control" "$d_fixture"
    return 1
  fi
  d_child=$(cat "$d_control/child_pid")
  # Poll (no arbitrary sleep): the descendant must already be gone; a short
  # grace window absorbs process-table lag only.
  d_waited=0
  while kill -0 "$d_child" 2>/dev/null && [ "$d_waited" -lt 10 ]; do
    sleep 1
    d_waited=$((d_waited + 1))
  done
  if kill -0 "$d_child" 2>/dev/null; then
    gz_log "[FAIL] compiler descendant $d_child survived manager shutdown" >&2
    rm -rf "$d_control" "$d_fixture"
    return 1
  fi
  rm -rf "$d_control" "$d_fixture"
  gz_assert_shutdown_clean "$d_log" || return 1
  gz_assert_no_orphans || return 1
  gz_log "[PASS] Validate compiler process-tree cleanup"
  return 0
}

do_compiler_output() {
  exec_godot_script compiler output "Validate compiler output limits" \
    tests/compiler_output_runner.gd GZSCRIPT_COMPILER_OUTPUT_OK
}

do_compiler_version() {
  gz_log "[EXPECT] Compiler version tests intentionally select an incompatible Zig"
  exec_godot_script compiler version "Validate compiler version enforcement" \
    tests/compiler_version_runner.gd GZSCRIPT_COMPILER_VERSION_OK
}

do_compiler_failure() {
  gz_log "[EXPECT] Failure tests compile intentionally invalid Zig source and ABI metadata"
  exec_godot_script compiler failure "Validate compilation failure handling" \
    tests/failure_runner.gd GZSCRIPT_FAILURE_HANDLING_OK
}

do_compiler_atomic() {
  exec_godot_script compiler atomic "Validate crash-atomic resource saves" \
    tests/save_atomic_runner.gd GZSCRIPT_SAVE_ATOMIC_OK
}

do_compiler_fixture_selftest() {
  exec_shell compiler fixture-selftest "Validate fake compiler fixtures" \
    -- sh "$ROOT/tests/fixtures/fake_tools/selftest.sh"
}

do_cache_reuse() {
  gz_log "[EXPECT] Cache tests reject worker compilation and intentionally corrupt modules"
  rm -rf "$ROOT/.godot/gzscript"
  exec_godot_script cache reuse "Validate module cache and reloads" \
    tests/cache_runner.gd GZSCRIPT_CACHE_OK
}

do_concurrency_race() {
  exec_godot_script concurrency race "Validate compilation identity races" \
    tests/compiler_race_runner.gd GZSCRIPT_COMPILER_RACE_OK
}

do_concurrency_lock() {
  exec_godot_script concurrency lock "Validate cross-process compiler locking" \
    tests/compiler_lock_runner.gd GZSCRIPT_COMPILER_LOCK_OK
}

do_runtime_bindings() {
  exec_godot_script runtime bindings "Validate live bindings and ABI" \
    tests/live_bindings_runner.gd GZSCRIPT_LIVE_BINDINGS_OK
}

do_runtime_threaded() {
  gz_log "[EXPECT] Threaded Zig resource loading is intentionally rejected"
  exec_godot_script runtime threaded "Validate threaded-load rejection" \
    tests/threaded_load_runner.gd GZSCRIPT_THREADED_LOAD_OK
}

do_lifecycle_shutdown() {
  exec_godot_script lifecycle shutdown "Validate script/module/instance lifecycle" \
    tests/lifecycle/shutdown_runner.gd GZSCRIPT_LIFECYCLE_OK
}

do_lifecycle_abandon() {
  # run_godot is a shell function, so the mode flag travels via an exported
  # variable (prefixing `env` before a function name fails with 127).
  GZ_LIFECYCLE_ABANDON=1
  export GZ_LIFECYCLE_ABANDON
  d_abandon_status=0
  exec_godot_script lifecycle abandon "Validate lifecycle with instances abandoned in tree" \
    tests/lifecycle/shutdown_runner.gd GZSCRIPT_LIFECYCLE_OK || d_abandon_status=$?
  unset GZ_LIFECYCLE_ABANDON
  return "$d_abandon_status"
}

do_lsp_completion() {
  if ! gz_require_zls; then
    return 3
  fi
  do_editor_language_body lsp completion
}

do_editor_language_body() {
  e_body_group=${1:-editor}
  e_body_name=${2:-language}
  gz_require_godot || return $?
  gz_require_zig || return $?
  ensure_imported || return $?
  e_body_log=$(gz_results_dir "$e_body_group")/$e_body_name.log
  mkdir -p "$(gz_results_dir "$e_body_group")"
  gz_log "[RUN] Validate editor language integration"
  e_body_output=
  e_body_status=0
  if e_body_output=$(run_godot --editor --script tests/language_runner.gd 2>&1); then
    :
  else
    e_body_status=$?
  fi
  printf '%s\n' "$e_body_output" >"$e_body_log"
  printf '%s\n' "$e_body_output"
  rm -f "$ROOT/editor_test.zig" "$ROOT/editor_test.zig.uid" "$ROOT/editor_test.tscn"
  if [ "$e_body_status" -ne 0 ]; then
    gz_log "[FAIL] Validate editor language integration: $(gz_decode_exit "$e_body_status")" >&2
    return "$e_body_status"
  fi
  case "$e_body_output" in
    *"Required virtual method"* | *"delimiter must start with a symbol"* | *"auto brace completion open key must be a symbol"* | *'!ret.has("force")'* | *'!ret.has("call_hint")'* | *'!ret.has("type")'*)
      gz_log "[FAIL] Validate editor language integration: Godot emitted editor API errors" >&2
      return 1
      ;;
  esac
  case "$e_body_output" in
    *"GZSCRIPT_LANGUAGE_OK"*) ;;
    *)
      gz_log "[FAIL] Validate editor language integration: success token missing" >&2
      return 1
      ;;
  esac
  gz_assert_shutdown_clean "$e_body_log" || return 1
  gz_assert_no_orphans || return 1
  gz_log "[PASS] Validate editor language integration"
  return 0
}

do_editor_language() {
  do_editor_language_body editor language
}

do_integration_basic() {
  gz_require_godot || return $?
  gz_require_zig || return $?
  ensure_imported || return $?
  d_basic_log=$(gz_results_dir integration)/basic.log
  mkdir -p "$(gz_results_dir integration)"
  gz_log "[RUN] Run basic integration scene"
  d_basic_status=0
  run_godot >"$d_basic_log" 2>&1 || d_basic_status=$?
  cat "$d_basic_log"
  if [ "$d_basic_status" -ne 0 ]; then
    gz_log "[FAIL] Run basic integration scene: $(gz_decode_exit "$d_basic_status")" >&2
    return "$d_basic_status"
  fi
  gz_assert_shutdown_clean "$d_basic_log" || return 1
  gz_assert_no_orphans || return 1
  gz_log "[PASS] Run basic integration scene"
  return 0
}

do_stress_lifecycle_loops() {
  exec_shell stress lifecycle-loops "Stress lifecycle ($STRESS_ITERATIONS iterations)" \
    -- sh "$ROOT/tests/lifecycle/stress_shutdown.sh" "$STRESS_ITERATIONS"
}

do_smoke_project() {
  exec_shell smoke project "Cross-platform runtime smoke (cold/warm/recompile)" \
    -- sh "$ROOT/tests/smoke/run.sh"
}

# --- runner ---------------------------------------------------------------
# run_one_test <group> <name>: timing, metadata, flake rerun, summary line.
run_one_test() {
  t_group=$1
  t_name=$2
  t_fn=$(printf 'do_%s_%s' "$t_group" "$t_name" | tr '/-' '__')
  t_start=$(gz_millis)
  t_status=0
  if ! command -v "$t_fn" >/dev/null 2>&1; then
    gz_log "[FAIL] unknown test: $t_group/$t_name" >&2
    return 2
  fi
  "$t_fn" || t_status=$?
  if [ "$t_status" -eq 3 ]; then
    t_end=$(gz_millis)
    gz_record_result "$t_group/$t_name" "$t_group" "skipped" 0 $((t_end - t_start))
    printf 'SKIP %s/%s\n' "$t_group" "$t_name" >>"$SUMMARY_FILE"
    gz_log "[SKIP] $t_group/$t_name"
    return 0
  fi
  if [ "$t_status" -ne 0 ] && [ "${GZSCRIPT_RERUN_ON_FAIL:-0}" = "1" ]; then
    gz_log "[RETRY] $t_group/$t_name failed once; rerunning to detect flakiness"
    t_retry_status=0
    "$t_fn" >/dev/null 2>&1 || t_retry_status=$?
    if [ "$t_retry_status" -eq 0 ]; then
      t_end=$(gz_millis)
      gz_record_result "$t_group/$t_name" "$t_group" "flaky" "$t_status" $((t_end - t_start))
      printf 'FLAKY %s/%s (first: %s)\n' "$t_group" "$t_name" "$(gz_decode_exit "$t_status")" >>"$SUMMARY_FILE"
      gz_log "[FLAKY] $t_group/$t_name (failed, then passed on rerun)" >&2
      RESULTS_FLAKY=$((RESULTS_FLAKY + 1))
      RESULTS_FAILED=$((RESULTS_FAILED + 1))
      return 1
    fi
  fi
  t_end=$(gz_millis)
  if [ "$t_status" -ne 0 ]; then
    gz_record_result "$t_group/$t_name" "$t_group" "failed" "$t_status" $((t_end - t_start))
    printf 'FAIL %s/%s (%s)\n' "$t_group" "$t_name" "$(gz_decode_exit "$t_status")" >>"$SUMMARY_FILE"
    RESULTS_FAILED=$((RESULTS_FAILED + 1))
    return "$t_status"
  fi
  gz_record_result "$t_group/$t_name" "$t_group" "passed" 0 $((t_end - t_start))
  printf 'PASS %s/%s\n' "$t_group" "$t_name" >>"$SUMMARY_FILE"
  return 0
}

GROUP_TESTS() {
  case "$1" in
    build) printf 'extension import' ;;
    quality) printf 'format' ;;
    unit) printf 'zig' ;;
    compiler) printf 'save tree output version failure atomic fixture-selftest' ;;
    cache) printf 'reuse' ;;
    concurrency) printf 'race lock' ;;
    runtime) printf 'bindings threaded' ;;
    lifecycle) printf 'shutdown abandon' ;;
    lsp) printf 'completion' ;;
    editor) printf 'language' ;;
    integration) printf 'basic' ;;
    smoke) printf 'project' ;;
    stress) printf 'lifecycle-loops' ;;
  esac
}

expand_target() {
  case "$1" in
    fast) printf 'build quality unit compiler cache runtime/bindings lifecycle' ;;
    full) printf 'build quality unit compiler cache concurrency runtime lifecycle lsp editor integration smoke' ;;
    stress) printf 'stress' ;;
    *) printf '%s' "$1" ;;
  esac
}

run_group() {
  g_group=$1
  # shellcheck disable=SC2046
  for g_test in $(GROUP_TESTS "$g_group"); do
    run_one_test "$g_group" "$g_test" || true
  done
}

print_summary() {
  gz_log ""
  gz_log "gzscript test summary"
  gz_log ""
  sort "$SUMMARY_FILE" | while IFS= read -r p_line; do
    gz_log "  $p_line"
  done
  p_pass=$(grep -c '^PASS' "$SUMMARY_FILE" || true)
  p_fail=$(grep -c '^FAIL' "$SUMMARY_FILE" || true)
  p_skip=$(grep -c '^SKIP' "$SUMMARY_FILE" || true)
  p_flaky=$(grep -c '^FLAKY' "$SUMMARY_FILE" || true)
  gz_log ""
  gz_log "Passed:   $p_pass"
  gz_log "Failed:   $p_fail"
  gz_log "Skipped:  $p_skip"
  gz_log "Flaky:    $p_flaky"
  for p_g in build quality unit compiler cache concurrency runtime lifecycle lsp editor integration smoke stress; do
    if [ -f "$(gz_results_dir "$p_g")/results.jsonl" ]; then
      gz_write_junit "$p_g"
    fi
  done
}

main() {
  if [ $# -eq 0 ]; then
    set -- full
  fi
  for m_arg in "$@"; do
    case "$m_arg" in
      -h|--help) usage; return 0 ;;
      --list) list_tests; return 0 ;;
      --no-build) SKIP_BUILD=1; GZSCRIPT_SKIP_BUILD=1; export GZSCRIPT_SKIP_BUILD ;;
      --flake-check) GZSCRIPT_RERUN_ON_FAIL=1; export GZSCRIPT_RERUN_ON_FAIL ;;
      -*) gz_log "unknown option: $m_arg" >&2; usage >&2; return 2 ;;
    esac
  done

  setup_invocation
  gz_print_environment

  m_valid_groups=" build quality unit compiler cache concurrency runtime lifecycle lsp editor integration smoke stress "
  m_needs_build=0
  m_wipe_cache=0
  for m_arg in "$@"; do
    case "$m_arg" in
      -*) continue ;;
    esac
    for m_target in $(expand_target "$m_arg"); do
      case "$m_target" in
        */*) m_g=${m_target%%/*} ;;
        *) m_g=$m_target ;;
      esac
      case "$m_valid_groups" in
        *" $m_g "*) : ;;
        *) gz_log "unknown group or test: $m_target" >&2; return 2 ;;
      esac
      m_needs_build=1
      case "$m_g" in
        cache) m_wipe_cache=1 ;;
      esac
    done
  done

  if [ "$m_needs_build" = "1" ] && [ "$SKIP_BUILD" = "0" ]; then
    if ! (cd "$ROOT" && zig build --prefix . -Doptimize="$BUILD_MODE"); then
      gz_log "[FAIL] build (zig build exited nonzero)" >&2
      cleanup_invocation
      return 1
    fi
    rm -rf "$ROOT/.godot/gzscript"
  elif [ "$m_wipe_cache" = "1" ]; then
    rm -rf "$ROOT/.godot/gzscript"
  fi

  for m_arg in "$@"; do
    case "$m_arg" in
      -*) continue ;;
    esac
    for m_target in $(expand_target "$m_arg"); do
      case "$m_target" in
        */*)
          m_g=${m_target%%/*}
          m_t=${m_target#*/}
          run_one_test "$m_g" "$m_t" || true
          ;;
        *)
          run_group "$m_target" || true
          ;;
      esac
    done
  done

  print_summary
  cleanup_invocation
  if [ "$RESULTS_FAILED" -ne 0 ]; then
    return 1
  fi
  return 0
}

main "$@"
