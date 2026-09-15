#!/bin/sh
# Shared test harness for gzscript. POSIX sh compatible (dash-safe).
# Sourced by tests/run.sh, never executed directly.
#
# Variable discipline: this file owns the `gz_` prefix. All internal
# temporaries use `gz_` + function-specific names so nested calls can never
# clobber the caller's state (POSIX sh has no local variables).
#
# Environment (see tests/config.env):
#   GODOT_BIN / ZIG_BIN / ZLS_BIN   tool overrides
#   BUILD_MODE                       Debug | ReleaseFast
#   GZSCRIPT_TEST_VERBOSE=1          echo commands, PIDs, paths
#   GZSCRIPT_TRACE=1                 pass --verbose to Godot invocations
#   GZSCRIPT_KEEP_TEST_ARTIFACTS=1   retain temp dirs on failure
#   GZSCRIPT_RERUN_ON_FAIL=1         rerun a failed test once, report FLAKY

# shellcheck disable=SC2034
GZ_COMMON_LOADED=1

gz_repo_root() {
  unset CDPATH
  cd -- "$(dirname -- "$0")/.." && pwd
}

gz_load_config() {
  gz_config_root=$(gz_repo_root)
  if [ -f "$gz_config_root/tests/config.env" ]; then
    # shellcheck disable=SC1091
    . "$gz_config_root/tests/config.env"
  fi
  : "${BUILD_MODE:=Debug}"
  : "${GZSCRIPT_SKIP_BUILD:=0}"
  : "${GZSCRIPT_RERUN_ON_FAIL:=0}"
  : "${GZSCRIPT_KEEP_TEST_ARTIFACTS:=0}"
  : "${GZSCRIPT_TEST_VERBOSE:=0}"
  : "${GZSCRIPT_TRACE:=0}"
  : "${GZSCRIPT_TEST_SEED:=0}"
  : "${TIMEOUT_COMPILER:=120}"
  : "${TIMEOUT_CACHE:=120}"
  : "${TIMEOUT_CONCURRENCY:=180}"
  : "${TIMEOUT_RUNTIME:=120}"
  : "${TIMEOUT_LIFECYCLE:=120}"
  : "${TIMEOUT_LSP:=180}"
  : "${TIMEOUT_EDITOR:=180}"
  : "${TIMEOUT_INTEGRATION:=180}"
  : "${TIMEOUT_STRESS:=1500}"
  : "${STRESS_ITERATIONS:=100}"
}

gz_log() {
  printf '%s\n' "$*"
}

gz_verbose() {
  if [ "${GZSCRIPT_TEST_VERBOSE:-0}" = "1" ]; then
    printf '[VERBOSE] %s\n' "$*" >&2
  fi
}

# Tool discovery with explicit overrides. Resolved once per run.
gz_discover_tools() {
  if [ -n "${GODOT_BIN:-}" ]; then
    gz_found_godot=$GODOT_BIN
  else
    gz_found_godot=$(command -v godot || true)
  fi
  if [ -n "${ZIG_BIN:-}" ]; then
    gz_found_zig=$ZIG_BIN
  else
    gz_found_zig=$(command -v zig || true)
  fi
  if [ -n "${ZLS_BIN:-}" ]; then
    gz_found_zls=$ZLS_BIN
  else
    gz_found_zls=$(command -v zls || true)
  fi
  # Resolve before PATH restriction (Homebrew coreutils on macOS).
  gz_found_timeout=$(command -v timeout || command -v gtimeout || true)
  GODOT_BIN_RESOLVED=$gz_found_godot
  ZIG_BIN_RESOLVED=$gz_found_zig
  ZLS_BIN_RESOLVED=$gz_found_zls
  TIMEOUT_BIN_RESOLVED=$gz_found_timeout
  export GODOT_BIN_RESOLVED ZIG_BIN_RESOLVED ZLS_BIN_RESOLVED TIMEOUT_BIN_RESOLVED
}

gz_require_godot() {
  if [ -z "${GODOT_BIN_RESOLVED:-}" ]; then
    gz_log "godot binary required but not found (set GODOT_BIN)" >&2
    return 2
  fi
}

gz_require_zig() {
  if [ -z "${ZIG_BIN_RESOLVED:-}" ]; then
    gz_log "zig binary required but not found (set ZIG_BIN)" >&2
    return 2
  fi
  if [ -n "${GZSCRIPT_ZIG_VERSION:-}" ]; then
    gz_probed_zig=$("$ZIG_BIN_RESOLVED" version 2>/dev/null || true)
    if [ "$gz_probed_zig" != "$GZSCRIPT_ZIG_VERSION" ]; then
      gz_log "Zig $GZSCRIPT_ZIG_VERSION required but found '${gz_probed_zig:-none}'" >&2
      return 2
    fi
  fi
}

# Returns 0 when usable, 3 when ZLS is absent (caller may skip).
gz_require_zls() {
  if [ -z "${ZLS_BIN_RESOLVED:-}" ]; then
    gz_log "ZLS required but not found (set ZLS_BIN); skipping" >&2
    return 3
  fi
}

gz_print_environment() {
  gz_env_godot=$(${GODOT_BIN_RESOLVED:-false} --version 2>/dev/null | head -n 1 || true)
  gz_env_zig=$(${ZIG_BIN_RESOLVED:-false} version 2>/dev/null || true)
  gz_env_zls=$(${ZLS_BIN_RESOLVED:-false} --version 2>/dev/null || true)
  gz_env_commit=$(git -C "$(gz_repo_root)" rev-parse --short HEAD 2>/dev/null || echo unknown)
  gz_log "gzscript test environment"
  gz_log "commit:        $gz_env_commit"
  gz_log "platform:      $(uname -s)-$(uname -m)"
  gz_log "configuration: ${BUILD_MODE:-Debug}"
  gz_log "Godot:         ${gz_env_godot:-missing} (${GODOT_BIN_RESOLVED:-unset})"
  gz_log "Zig:           ${gz_env_zig:-missing} (${ZIG_BIN_RESOLVED:-unset})"
  gz_log "ZLS:           ${gz_env_zls:-missing} (${ZLS_BIN_RESOLVED:-unset})"
  gz_log "seed:          ${GZSCRIPT_TEST_SEED:-0}"
}

# Portable timeout runner. Usage: gz_timeout_run <secs> <logfile> <cmd...>
gz_timeout_run() {
  gz_tr_secs=$1
  gz_tr_log=$2
  shift 2
  gz_verbose "run (timeout ${gz_tr_secs}s, log ${gz_tr_log}): $*"
  gz_tr_status=0
  if [ -n "${TIMEOUT_BIN_RESOLVED:-}" ]; then
    "$TIMEOUT_BIN_RESOLVED" "${gz_tr_secs}s" "$@" >"$gz_tr_log" 2>&1 || gz_tr_status=$?
  else
    "$@" >"$gz_tr_log" 2>&1 || gz_tr_status=$?
  fi
  cat "$gz_tr_log"
  return "$gz_tr_status"
}

# Decode well-known process exit codes for actionable output.
gz_decode_exit() {
  case "$1" in
    0) printf 'exit 0 (success)' ;;
    1) printf 'exit 1 (assertion/test failure)' ;;
    2) printf 'exit 2 (invalid test configuration)' ;;
    124) printf 'exit 124 (TIMEOUT)' ;;
    134) printf 'exit 134 (SIGABRT)' ;;
    137) printf 'exit 137 (SIGKILL)' ;;
    139) printf 'exit 139 (SIGSEGV)' ;;
    *) printf 'exit %s' "$1" ;;
  esac
}

# Results bookkeeping: test-results/<group>/results.jsonl + junit.xml.
gz_results_dir() {
  printf '%s/test-results/%s' "$(gz_repo_root)" "$1"
}

gz_record_result() {
  # name group status exit_code duration_ms
  gz_rec_dir=$(gz_results_dir "$2")
  mkdir -p "$gz_rec_dir"
  gz_rec_platform="$(uname -s)-$(uname -m)"
  printf '{"name":"%s","group":"%s","status":"%s","exit_code":%s,"duration_ms":%s,"platform":"%s","configuration":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$gz_rec_platform" "${BUILD_MODE:-Debug}" >>"$gz_rec_dir/results.jsonl"
}

gz_write_junit() {
  # group
  gz_junit_dir=$(gz_results_dir "$1")
  [ -f "$gz_junit_dir/results.jsonl" ] || return 0
  gz_junit_xml="$gz_junit_dir/junit.xml"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="gzscript-%s">\n' "$1"
    while IFS= read -r gz_junit_line; do
      gz_junit_name=$(printf '%s' "$gz_junit_line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
      gz_junit_status=$(printf '%s' "$gz_junit_line" | sed 's/.*"status":"\([^"]*\)".*/\1/')
      gz_junit_ms=$(printf '%s' "$gz_junit_line" | sed 's/.*"duration_ms":\([0-9]*\).*/\1/')
      gz_junit_code=$(printf '%s' "$gz_junit_line" | sed 's/.*"exit_code":\([0-9]*\).*/\1/')
      gz_junit_time=$(awk "BEGIN {print ${gz_junit_ms:-0}/1000}")
      printf '  <testcase classname="%s" name="%s" time="%s">' "$1" "$gz_junit_name" "$gz_junit_time"
      if [ "$gz_junit_status" != "passed" ]; then
        printf '<failure message="%s (exit %s)"/>' "$gz_junit_status" "$gz_junit_code"
      fi
      printf '</testcase>\n'
    done <"$gz_junit_dir/results.jsonl"
    printf '</testsuite>\n'
  } >"$gz_junit_xml"
}

gz_millis() {
  # Epoch milliseconds. `date +%s%N` yields ns/ms/s (or garbage) depending
  # on the platform, so normalize by digit width: 10=s, 13=ms, 19=ns.
  gz_clock=$(date +%s%N 2>/dev/null || true)
  case "$gz_clock" in
    ''|*[!0-9]*)
      gz_clock=$(date +%s 2>/dev/null || echo 0)
      gz_clock=${gz_clock}000
      ;;
  esac
  while [ "${#gz_clock}" -gt 13 ]; do
    gz_clock=${gz_clock%?}
  done
  while [ "${#gz_clock}" -lt 13 ]; do
    gz_clock=${gz_clock}0
  done
  printf '%s' "$gz_clock"
}

# Assert the Phase 1 debug counters returned to zero in a Godot log.
gz_assert_shutdown_clean() {
  gz_clean_log=$1
  gz_clean_summary=$(grep -h "shutdown summary" "$gz_clean_log" 2>/dev/null | tail -n 1 || true)
  if [ -z "$gz_clean_summary" ]; then
    return 0
  fi
  case "$gz_clean_summary" in
    *"scripts=0 instances=0 modules=0 compile_jobs=0 lsp=0"*) return 0 ;;
    *)
      gz_log "resource leak detected: $gz_clean_summary" >&2
      return 1
      ;;
  esac
}

# Fail (rather than silently kill) when test processes leak.
gz_assert_no_orphans() {
  gz_orphan_leaked=0
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f "zig .*gzscript" >/dev/null 2>&1; then
      gz_log "orphan zig compiler processes remain:" >&2
      pgrep -af "zig .*gzscript" >&2 || true
      gz_orphan_leaked=1
    fi
    if [ -n "${ZLS_BIN_RESOLVED:-}" ]; then
      gz_orphan_zls=$(basename "$ZLS_BIN_RESOLVED")
      if pgrep -f "$gz_orphan_zls" >/dev/null 2>&1; then
        gz_log "note: zls processes still running (may be shared with the desktop):" >&2
        pgrep -af "$gz_orphan_zls" >&2 || true
      fi
    fi
  fi
  return "$gz_orphan_leaked"
}
