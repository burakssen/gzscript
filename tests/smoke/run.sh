#!/bin/sh
# gzscript cross-platform runtime smoke test.
#
# Same fixture, same workflow on every target: isolated project (under a path
# with spaces), packaged addon, cold compile, warm reuse, source-change
# recompile, explicit destroy, clean shutdown. No ZLS required.
#
# Usage: sh tests/smoke/run.sh
# Env: GODOT_BIN/ZIG_BIN overrides, BUILD_MODE (selects template_debug or
#   template_release binaries), GZSCRIPT_SMOKE_ADDON_DIR (default: repo addon),
#   GZSCRIPT_KEEP_TEST_ARTIFACTS=1 to retain the work dir.
set -eu
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/scripts/common.sh"

gz_load_config
gz_discover_tools
: "${TIMEOUT_SMOKE:=300}"
: "${GZSCRIPT_SMOKE_ADDON_DIR:=$REPO_ROOT/addons/gzscript}"

SMOKE_FAIL_CATEGORY=""
smoke_fail() {
  # <category> <message>
  SMOKE_FAIL_CATEGORY=$1
  shift
  printf 'SMOKE FAILED: %s\n%s\n' "$SMOKE_FAIL_CATEGORY" "$*" >&2
}

# Canonical internal arch names: x86_64/aarch64. Map to upstream spellings.
smoke_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64' ;;
    arm64|aarch64) printf 'aarch64' ;;
    *) printf 'unknown' ;;
  esac
}

smoke_host_os() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*|Windows*) printf 'windows' ;;
    *) printf 'unknown' ;;
  esac
}

main() {
  if smoke_stages; then
    return 0
  else
    smoke_preserve
    return 1
  fi
}

smoke_stages() {
  SMOKE_OS=$(smoke_host_os)
  SMOKE_ARCH=$(smoke_host_arch)
  SMOKE_PLATFORM="$SMOKE_OS-$SMOKE_ARCH"
  printf 'gzscript runtime smoke\nPlatform: %s\n' "$SMOKE_PLATFORM"

  # --- Stage 0: environment validation -----------------------------------
  printf '[1/6] Validate environment\n'
  if [ -z "${GODOT_BIN_RESOLVED:-}" ]; then
    smoke_fail ENVIRONMENT_FAILURE "godot binary not found (set GODOT_BIN)"
    return 2
  fi
  if [ -z "${ZIG_BIN_RESOLVED:-}" ]; then
    smoke_fail ENVIRONMENT_FAILURE "zig binary not found (set ZIG_BIN)"
    return 2
  fi
  SMOKE_GODOT_V=$("$GODOT_BIN_RESOLVED" --version 2>/dev/null | head -n 1 || true)
  SMOKE_ZIG_V=$("$ZIG_BIN_RESOLVED" version 2>/dev/null || true)
  printf 'Godot: %s\nZig:   %s\n' "$SMOKE_GODOT_V" "$SMOKE_ZIG_V"
  if [ "$SMOKE_ZIG_V" != "${GZSCRIPT_ZIG_VERSION:-0.16.0}" ]; then
    smoke_fail ENVIRONMENT_FAILURE "Zig ${GZSCRIPT_ZIG_VERSION:-0.16.0} required, found '$SMOKE_ZIG_V'"
    return 2
  fi
  if [ "$SMOKE_OS" = "unknown" ] || [ "$SMOKE_ARCH" = "unknown" ]; then
    smoke_fail ENVIRONMENT_FAILURE "unsupported host: $(uname -s)-$(uname -m)"
    return 2
  fi
  if [ ! -d "$GZSCRIPT_SMOKE_ADDON_DIR" ]; then
    smoke_fail PACKAGE_FAILURE "addon dir missing: $GZSCRIPT_SMOKE_ADDON_DIR"
    return 2
  fi
  # Architecture cross-check where the `file` tool exists.
  if command -v file >/dev/null 2>&1; then
    SMOKE_GODOT_ARCH_OK=0
    case "$SMOKE_ARCH" in
      x86_64) file "$GODOT_BIN_RESOLVED" | grep -qiE "x86.?64" && SMOKE_GODOT_ARCH_OK=1 || true ;;
      aarch64) file "$GODOT_BIN_RESOLVED" | grep -qiE "arm64|aarch64" && SMOKE_GODOT_ARCH_OK=1 || true ;;
    esac
    if [ "$SMOKE_GODOT_ARCH_OK" != "1" ]; then
      smoke_fail ENVIRONMENT_FAILURE "Godot arch mismatch: $(file -b "$GODOT_BIN_RESOLVED" | cut -c1-80)"
      return 2
    fi
  fi

  # --- Stage 1: isolated project ------------------------------------------
  printf '[2/6] Prepare isolated project\n'
  SMOKE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/gzscript-smoke-XXXXXX")
  # Path with spaces on every platform: exercises command quoting.
  SMOKE_PROJECT="$SMOKE_WORK/gzscript smoke test/project"
  SMOKE_HOME="$SMOKE_WORK/home"
  SMOKE_LOGS="$SMOKE_WORK/logs"
  mkdir -p "$SMOKE_PROJECT/addons" "$SMOKE_HOME" "$SMOKE_LOGS"
  cp -R "$GZSCRIPT_SMOKE_ADDON_DIR" "$SMOKE_PROJECT/addons/gzscript"
  cp "$REPO_ROOT/tests/smoke/project/project.godot" \
    "$REPO_ROOT/tests/smoke/project/smoke.zig" \
    "$REPO_ROOT/tests/smoke/project/smoke_runner.gd" \
    "$SMOKE_PROJECT/"

  # Verify the .gdextension mapping resolves to an existing binary.
  SMOKE_GDEXT_ARCH=$SMOKE_ARCH
  if [ "$SMOKE_GDEXT_ARCH" = "aarch64" ]; then
    SMOKE_GDEXT_ARCH=arm64
  fi
  SMOKE_BUILD_TYPE=debug
  if [ "${BUILD_MODE:-Debug}" = "ReleaseFast" ]; then
    SMOKE_BUILD_TYPE=release
  fi
  SMOKE_LIB_LINE=$(grep -E "^${SMOKE_OS}\.${SMOKE_BUILD_TYPE}\\.single\\.${SMOKE_GDEXT_ARCH}[[:space:]]*=" \
    "$SMOKE_PROJECT/addons/gzscript/gzscript.gdextension" || true)
  if [ -z "$SMOKE_LIB_LINE" ]; then
    smoke_fail PACKAGE_FAILURE "no .gdextension mapping for $SMOKE_OS.$SMOKE_BUILD_TYPE.$SMOKE_GDEXT_ARCH"
    return 2
  fi
  SMOKE_LIB_REL=$(printf '%s' "$SMOKE_LIB_LINE" | sed 's/^[^=]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/')
  case "$SMOKE_LIB_REL" in
    res://*) SMOKE_LIB_FS="$SMOKE_PROJECT/${SMOKE_LIB_REL#res://}" ;;
    *) SMOKE_LIB_FS="$SMOKE_LIB_REL" ;;
  esac
  if [ ! -e "$SMOKE_LIB_FS" ]; then
    smoke_fail PACKAGE_FAILURE "mapped binary missing: $SMOKE_LIB_REL"
    return 2
  fi
  printf 'extension: %s\n' "$SMOKE_LIB_REL"

  # Seed extension registration deterministically, then populate Godot's
  # project caches (extension discovery, uid cache) via editor import.
  # Fresh projects crash some hosts' editor layout/driver init (observed:
  # MoltenVK segfault on headless macOS), so retry once with opengl3.
  mkdir -p "$SMOKE_PROJECT/.godot"
  printf 'res://addons/gzscript/gzscript.gdextension\n' >"$SMOKE_PROJECT/.godot/extension_list.cfg"

  # Populate Godot's project caches (extension discovery, uid cache). Try the
  # default driver first; some hosts need opengl3 for editor import bootstrap.
  printf 'import project caches\n'
  SMOKE_IMPORT_STATUS=0
  (cd "$SMOKE_WORK" && \
    env PATH=/usr/bin:/bin HOME="$SMOKE_HOME" \
    GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" GZSCRIPT_ZLS_PATH="" \
    "$GODOT_BIN_RESOLVED" --headless --path "$SMOKE_PROJECT" --import >"$SMOKE_LOGS/import.log" 2>&1) || SMOKE_IMPORT_STATUS=$?
  if [ "$SMOKE_IMPORT_STATUS" -ne 0 ]; then
    printf 'import with default driver failed (%s); retrying with opengl3\n' "$(gz_decode_exit "$SMOKE_IMPORT_STATUS")"
    SMOKE_IMPORT_STATUS=0
    (cd "$SMOKE_WORK" && \
      env PATH=/usr/bin:/bin HOME="$SMOKE_HOME" \
      GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" GZSCRIPT_ZLS_PATH="" \
      "$GODOT_BIN_RESOLVED" --headless --rendering-driver opengl3 --path "$SMOKE_PROJECT" --import >"$SMOKE_LOGS/import.log" 2>&1) || SMOKE_IMPORT_STATUS=$?
  fi
  cat "$SMOKE_LOGS/import.log"
  if [ "$SMOKE_IMPORT_STATUS" -ne 0 ]; then
    smoke_fail EXTENSION_LOAD_FAILURE "import failed: $(gz_decode_exit "$SMOKE_IMPORT_STATUS")"
    return 1
  fi

  SMOKE_COLD_OK=0
  SMOKE_WARM_OK=0
  SMOKE_RECOMPILE_OK=0

  # --- Stage 2: cold compile + execute ------------------------------------
  # The temp project starts with an empty gzscript cache: this run must
  # compile the Zig script itself (no prebuilt user module is packaged).
  printf '[3/6] Cold compile and execute\n'
  if ! smoke_godot_run cold 1; then
    return 1
  fi
  SMOKE_COLD_OK=1
  SMOKE_MODULE=$(find "$SMOKE_PROJECT/.godot" \( -name '*.so' -o -name '*.dylib' -o -name '*.dll' \) -print 2>/dev/null | head -n 1 || true)
  if [ -z "$SMOKE_MODULE" ]; then
    smoke_fail COMPILER_FAILURE "no compiled native module produced"
    return 1
  fi
  SMOKE_MODULE_HASH=$(smoke_hash "$SMOKE_MODULE")
  printf 'module: %s\n' "$SMOKE_MODULE"

  # --- Stage 3: warm cache reuse -------------------------------------------
  printf '[4/6] Warm cache reuse\n'
  if ! smoke_godot_run warm 1; then
    return 1
  fi
  SMOKE_MODULE2=$(find "$SMOKE_PROJECT/.godot" \( -name '*.so' -o -name '*.dylib' -o -name '*.dll' \) -print 2>/dev/null | head -n 1 || true)
  if [ "$SMOKE_MODULE2" != "$SMOKE_MODULE" ] || [ "$(smoke_hash "$SMOKE_MODULE2")" != "$SMOKE_MODULE_HASH" ]; then
    smoke_fail COMPILER_FAILURE "warm run did not reuse the cached module"
    return 1
  fi
  SMOKE_WARM_OK=1

  # --- Stages 4+5: source change + recompile --------------------------------
  printf '[5/6] Source modification and recompile\n'
  sed 's/version: i64 = 1,/version: i64 = 2,/' "$SMOKE_PROJECT/smoke.zig" >"$SMOKE_WORK/smoke2.zig"
  sed 's/\.version = 1,/.version = 2,/' "$SMOKE_WORK/smoke2.zig" >"$SMOKE_PROJECT/smoke.zig"
  grep -q "version: i64 = 2," "$SMOKE_PROJECT/smoke.zig" || {
    smoke_fail ENVIRONMENT_FAILURE "source modification failed"
    return 2
  }
  if ! smoke_godot_run recompile 2; then
    return 1
  fi
  SMOKE_RECOMPILE_OK=1

  # --- Stage 6: cleanup verification ----------------------------------------
  printf '[6/6] Process cleanup\n'
  if ! gz_assert_no_orphans; then
    smoke_fail SHUTDOWN_FAILURE "orphan processes remain"
    return 1
  fi
  smoke_preserve_results
  if [ "${GZSCRIPT_KEEP_TEST_ARTIFACTS:-0}" = "1" ]; then
    printf 'keeping smoke work dir: %s\n' "$SMOKE_WORK"
  else
    rm -rf "$SMOKE_WORK"
  fi

  SMOKE_COLD_LABEL=FAIL
  SMOKE_WARM_LABEL=FAIL
  SMOKE_RECOMPILE_LABEL=FAIL
  [ "$SMOKE_COLD_OK" = "1" ] && SMOKE_COLD_LABEL=PASS || true
  [ "$SMOKE_WARM_OK" = "1" ] && SMOKE_WARM_LABEL=PASS || true
  [ "$SMOKE_RECOMPILE_OK" = "1" ] && SMOKE_RECOMPILE_LABEL=PASS || true
  printf '\ngzscript runtime smoke\n\nPlatform:      %s\nBuild:         %s\n\nCold run:      %s\nWarm run:      %s\nRecompile:     %s\nShutdown:      PASS\n\nGodot:         %s\nZig:           %s\n\nResult: PASS\n' \
    "$SMOKE_PLATFORM" "${BUILD_MODE:-Debug}" \
    "$SMOKE_COLD_LABEL" "$SMOKE_WARM_LABEL" "$SMOKE_RECOMPILE_LABEL" \
    "$SMOKE_GODOT_V" "$SMOKE_ZIG_V"
  return 0
}

# Always keep machine-readable results (cross-platform comparison); on
# failure also keep logs, the compiled module, and environment metadata.
smoke_preserve_results() {
  SMOKE_OUT="$REPO_ROOT/test-results/smoke"
  mkdir -p "$SMOKE_OUT"
  if [ -n "${SMOKE_LOGS:-}" ] && [ -d "$SMOKE_LOGS" ]; then
    cp "$SMOKE_LOGS/"*-result.json "$SMOKE_OUT/" 2>/dev/null || true
  fi
}

smoke_preserve() {
  smoke_preserve_results
  SMOKE_OUT="$REPO_ROOT/test-results/smoke"
  if [ -n "${SMOKE_LOGS:-}" ] && [ -d "$SMOKE_LOGS" ]; then
    cp "$SMOKE_LOGS/"*.log "$SMOKE_OUT/" 2>/dev/null || true
  fi
  {
    printf 'platform: %s\nbuild: %s\ncommit: ' "${SMOKE_PLATFORM:-unknown}" "${BUILD_MODE:-Debug}"
    git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
    printf '\ngodot: %s\nzig: %s\n' "${SMOKE_GODOT_V:-unknown}" "${SMOKE_ZIG_V:-unknown}"
  } >"$SMOKE_OUT/env.txt" 2>/dev/null || true
  if [ -n "${SMOKE_MODULE:-}" ] && [ -f "$SMOKE_MODULE" ]; then
    cp "$SMOKE_MODULE" "$SMOKE_OUT/" 2>/dev/null || true
  fi
  # Dependency inventory on module-load failures (best effort per platform).
  if [ "${SMOKE_FAIL_CATEGORY:-}" = "MODULE_LOAD_FAILURE" ] && [ -n "${SMOKE_MODULE:-}" ]; then
    if command -v ldd >/dev/null 2>&1; then
      ldd "$SMOKE_MODULE" >"$SMOKE_OUT/dependencies.txt" 2>&1 || true
    elif command -v otool >/dev/null 2>&1; then
      otool -L "$SMOKE_MODULE" >"$SMOKE_OUT/dependencies.txt" 2>&1 || true
    fi
  fi
}

smoke_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    wc -c <"$1" | tr -d ' '
  fi
}

# smoke_godot_run <stage> <expect_version>: execute + validate.
smoke_godot_run() {
  SMOKE_STAGE=$1
  SMOKE_EXPECT=$2
  SMOKE_LOG="$SMOKE_LOGS/$SMOKE_STAGE.log"
  SMOKE_STATUS=0
  # Launch from an unrelated working directory: no CWD assumptions.
  if [ -n "${TIMEOUT_BIN_RESOLVED:-}" ]; then
    (cd "$SMOKE_WORK" && \
      env PATH=/usr/bin:/bin HOME="$SMOKE_HOME" \
      GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" GZSCRIPT_ZLS_PATH="" \
      GZSCRIPT_SMOKE_EXPECT_VERSION="$SMOKE_EXPECT" \
      "$TIMEOUT_BIN_RESOLVED" "${TIMEOUT_SMOKE}s" \
      "$GODOT_BIN_RESOLVED" --headless --path "$SMOKE_PROJECT" \
      --script res://smoke_runner.gd >"$SMOKE_LOG" 2>&1) || SMOKE_STATUS=$?
  else
    (cd "$SMOKE_WORK" && \
      env PATH=/usr/bin:/bin HOME="$SMOKE_HOME" \
      GZSCRIPT_ZIG_PATH="$ZIG_BIN_RESOLVED" GZSCRIPT_ZLS_PATH="" \
      GZSCRIPT_SMOKE_EXPECT_VERSION="$SMOKE_EXPECT" \
      "$GODOT_BIN_RESOLVED" --headless --path "$SMOKE_PROJECT" \
      --script res://smoke_runner.gd >"$SMOKE_LOG" 2>&1) || SMOKE_STATUS=$?
  fi
  cat "$SMOKE_LOG"
  if [ "$SMOKE_STATUS" -ne 0 ]; then
    smoke_classify_failure "$SMOKE_LOG" "$SMOKE_STATUS"
    return 1
  fi
  for SMOKE_MARKER in GZSCRIPT_SMOKE_SCRIPT_LOADED GZSCRIPT_SMOKE_READY \
    GZSCRIPT_SMOKE_PROPERTY_OK GZSCRIPT_SMOKE_METHOD_OK \
    GZSCRIPT_SMOKE_VALUE_OK GZSCRIPT_SMOKE_DESTROY_OK GZSCRIPT_SMOKE_OK; do
    if ! grep -q "$SMOKE_MARKER" "$SMOKE_LOG"; then
      smoke_fail RUNTIME_FAILURE "marker $SMOKE_MARKER missing ($SMOKE_STAGE)"
      return 1
    fi
  done
  SMOKE_RESULT="$SMOKE_PROJECT/smoke-result.json"
  if [ ! -f "$SMOKE_RESULT" ]; then
    smoke_fail RUNTIME_FAILURE "smoke-result.json missing ($SMOKE_STAGE)"
    return 1
  fi
  for SMOKE_FIELD in '"ready":true' '"property":true' '"method":true' \
    '"godot_api":true' '"structured_value":true' '"string":true' \
    '"signal":true' '"destroy":true' "\"version\":$SMOKE_EXPECT"; do
    if ! grep -q "$SMOKE_FIELD" "$SMOKE_RESULT"; then
      smoke_fail ABI_FAILURE "result field $SMOKE_FIELD missing ($SMOKE_STAGE)"
      return 1
    fi
  done
  cp "$SMOKE_RESULT" "$SMOKE_LOGS/$SMOKE_STAGE-result.json"
  if ! gz_assert_shutdown_clean "$SMOKE_LOG"; then
    smoke_fail SHUTDOWN_FAILURE "resource leak ($SMOKE_STAGE)"
    return 1
  fi
  return 0
}

smoke_classify_failure() {
  SMOKE_CF_LOG=$1
  SMOKE_CF_STATUS=$2
  case "$SMOKE_CF_STATUS" in
    124) smoke_fail TIMEOUT "godot timed out" ;;
    134) smoke_fail SHUTDOWN_FAILURE "SIGABRT ($(gz_decode_exit 134))" ;;
    139) smoke_fail RUNTIME_FAILURE "SIGSEGV ($(gz_decode_exit 139))" ;;
    *)
      if grep -qE "Can't open GDExtension|Error loading extension|Failed loading resource.*gdextension" "$SMOKE_CF_LOG"; then
        smoke_fail EXTENSION_LOAD_FAILURE "see $SMOKE_CF_LOG"
      elif grep -q "SMOKE FAILED: SCRIPT_LOAD_FAILURE" "$SMOKE_CF_LOG"; then
        smoke_fail SCRIPT_LOAD_FAILURE "see $SMOKE_CF_LOG"
      elif grep -qE "Compilation failed|Unable to start Zig|Zig .* incompatible" "$SMOKE_CF_LOG"; then
        smoke_fail COMPILER_FAILURE "see $SMOKE_CF_LOG"
      elif grep -qE "does not export|ABI does not match|descriptor is incomplete" "$SMOKE_CF_LOG"; then
        smoke_fail MODULE_LOAD_FAILURE "see $SMOKE_CF_LOG"
      elif grep -q "SMOKE FAILED" "$SMOKE_CF_LOG"; then
        smoke_fail "$(grep -o "SMOKE FAILED: [A-Z_]*" "$SMOKE_CF_LOG" | head -n 1 | cut -d' ' -f3)" "see $SMOKE_CF_LOG"
      else
        smoke_fail RUNTIME_FAILURE "$(gz_decode_exit "$SMOKE_CF_STATUS"); see $SMOKE_CF_LOG"
      fi
      ;;
  esac
  return 1
}

main "$@"
