# gzscript testing

A test should fail at the narrowest layer capable of detecting the problem.
Only behavior that genuinely requires Godot is tested through Godot.

## Layers

| Layer | What | Needs Godot? | Example |
|---|---|---|---|
| quality | fmt, shellcheck, generator consistency | no | `run.sh quality` |
| unit | Zig unit tests (bindings, SDK, adapter) | no | `run.sh unit` |
| compiler | compile jobs, processes, output, versions, failures | headless `--script` | `run.sh compiler` |
| cache | artifact keys, reuse, invalidation, locking, corruption | headless `--script` | `run.sh cache` |
| concurrency | races, cross-process locks | headless `--script` | `run.sh concurrency` |
| runtime | script behavior (bindings, rejections) | headless `--script` | `run.sh runtime` |
| lifecycle | create/destroy/reload/shutdown, module generations | headless `--script` | `run.sh lifecycle` |
| lsp | ZLS completion transport (skips without ZLS) | `--editor --script` | `run.sh lsp` |
| editor | language registration, reload, inspector refresh | `--editor --script` | `run.sh editor` |
| integration | realistic end-to-end (basic scene) | headless | `run.sh integration` |
| smoke | portable runtime proof (cold/warm/recompile) | headless `--script` | `run.sh smoke` |
| stress | repeated lifecycle loops (nightly/manual) | headless `--script` | `run.sh stress` |

## Commands

```bash
./tests/run.sh fast        # build + quality + unit + compiler + cache + runtime/bindings + lifecycle
./tests/run.sh full        # everything except stress (default with no args)
./tests/run.sh stress      # STRESS_ITERATIONS lifecycle loops (default 100)

./tests/run.sh lifecycle               # one group
./tests/run.sh lifecycle/shutdown      # one test
./tests/run.sh compiler/tree runtime/bindings

./tests/run.sh --no-build lifecycle    # reuse already-built binaries (what CI does)
./tests/run.sh --list                  # list groups and tests
./tests/run.sh --flake-check lifecycle # rerun failures once, report FLAKY (job still fails)
```

CI calls the same scripts (`sh tests/run.sh --no-build <group>`); there is no
separate CI-only test logic. Targeted repro: `sh tests/run_integration_linux.sh`;
minimal fixture directly: `sh tests/lifecycle/run.sh`.

## Requirements

- Zig 0.16.0, Godot 4.7.x, ZLS 0.16.x (optional; `lsp` skips without it).
- Versions are centralized in `tests/config.env` (must match CI pins).
- Overrides: `GODOT_BIN`, `ZIG_BIN`, `ZLS_BIN`, `BUILD_MODE=ReleaseFast`.
- Every run prints an environment header (commit, platform, tool versions,
  seed) into the log.

## How results work

- Per-test logs: `test-results/<group>/<test>.log` (fresh per invocation).
- Machine-readable rows: `test-results/<group>/results.jsonl`
  (`name, group, status, exit_code, duration_ms, platform, configuration`).
- JUnit: `test-results/<group>/junit.xml` (written at the end of each run).
- Console summary with per-test timing and Passed/Failed/Skipped/Flaky counts.
- Exit-code semantics: `0` pass, `1` assertion failure, `2` bad usage,
  `124` timeout, `134` SIGABRT, `139` SIGSEGV — decoded in failure lines,
  e.g. `FAIL lifecycle/shutdown (exit 134 (SIGABRT))`.
- Reproduce a CI failure with the exact command printed as
  `./tests/run.sh <group>/<test>`.

## Debugging knobs

```bash
GZSCRIPT_TEST_VERBOSE=1 ./tests/run.sh lifecycle   # commands, PIDs, paths
GZSCRIPT_TRACE=1 ./tests/run.sh lifecycle          # Godot --verbose
GZSCRIPT_KEEP_TEST_ARTIFACTS=1 ./tests/run.sh ...  # retain temp dirs
GZSCRIPT_RERUN_ON_FAIL=1 ./tests/run.sh ...        # same as --flake-check
```

Failures keep harness temp dirs automatically and print their paths.
Godot runs use an isolated `HOME` and restricted `PATH` with explicit tool
paths, so developer-local configuration cannot leak in.

## Leak detection

Debug builds print a shutdown summary on every Godot run:

```text
[GZ] shutdown summary: scripts=0 instances=0 modules=0 compile_jobs=0 lsp=0
```

The harness fails any test whose summary is nonzero — a cheap,
always-on leak check complementing sanitizers.

## Sanitizers (Linux)

This is also the `Linux / ASan + UBSan` CI job. Note: on macOS the
instrumented library builds and links, but running it under Godot is blocked
by Apple toolchain/dyld restrictions on preloading sanitizer runtimes into a
signed host — use Linux for sanitizer runs.

For native stacks: `gdb --args godot --headless --path . --script
tests/lifecycle/shutdown_runner.gd`, then `run`, `bt`, `thread apply all bt`.

## Stress

```bash
sh tests/lifecycle/stress_shutdown.sh 100   # default 100 iterations
STRESS_ITERATIONS=1000 sh tests/lifecycle/stress_shutdown.sh
```

Each iteration runs the full lifecycle fixture twice (explicit-free and
abandon-in-tree) and asserts no orphan compiler processes remain.

## Test inventory

| Test | Group | Godot | Editor | Zig | ZLS | Notes |
|---|---|---|---|---|---|---|
| format | quality | no | no | yes | no | fmt + check-bindings |
| zig | unit | no | no | yes | no | `zig build test` |
| save | compiler | script | no | yes | no | async queue; invalid source expected |
| tree | compiler | script | no | fake (sleep child) | no | process-tree kill; polls, no sleep |
| output | compiler | script | no | fake wrappers | no | 64 KiB output bound |
| version | compiler | script | no | fake wrappers | no | rejects wrong Zig |
| failure | compiler | script | no | yes (invalid) | no | controlled errors, no crash |
| atomic | compiler | script | no | yes | no | crash-atomic saves |
| fixture-selftest | compiler | no | no | no | no | validates fake fixtures |
| reuse | cache | script | no | yes | no | keys/reuse/corruption; wipes cache first |
| race | concurrency | script | no | wrapped | no | identity races |
| lock | concurrency | script | no | wrapped | no | cross-process locks |
| bindings | runtime | script | no | yes | no | live ABI probes |
| threaded | runtime | script | no | no | no | rejection is the pass condition |
| shutdown | lifecycle | script | no | yes | no | generations; old instance pins v1 |
| abandon | lifecycle | script | no | yes | no | quit with live instances |
| completion | lsp | editor | yes | yes | required | skips (not fails) without ZLS |
| language | editor | editor | yes | yes | optional | registration, reload, inspector |
| basic | integration | headless scene | no | yes | no | happy path + clean shutdown |
| project | smoke | isolated project | no | yes | no | cold/warm/recompile, no ZLS |
| lifecycle-loops | stress | script | no | yes | no | N× shutdown cycles |

Conventions: behavior-describing names (`cache/reuse`, never `test_fix_3`);
fake tools in `tests/fixtures/fake_tools/` keep process tests fast and
deterministic; canonical Zig sources in `tests/fixtures/zig/` (tests copy,
never mutate, fixtures).

## CI architecture

`build-artifacts.yml`: `bindings` + `quality` gate the `build` matrix; the
`test-linux` matrix (`Unit/Compiler/Cache/Concurrency/Runtime/Lifecycle/ZLS/
Editor/Integration`) downloads the `gzscript-linux-x86_64` artifact and runs
one group per job with `--flake-check`; `sanitizers-linux` builds with
`-Dsanitize` and runs lifecycle+compiler under ASan/UBSan; `smoke` matrix
(`Linux x86_64/ARM64`, `macOS ARM64`, `Windows x86_64`) downloads the matching
platform binaries and runs the portable smoke project; `package` needs
`build` + `test-linux`. JUnit uploads always; full `test-results/` and
process lists upload on failure.

## Cross-platform smoke tests

`tests/smoke/` is an isolated Godot project (own `project.godot`,
`smoke.zig`, `smoke_runner.gd`) proving the packaged addon works end to end
on a target: extension load, language registration, cold compile, instance
create, `_ready`, property/method/signal bridging, a Godot API call,
explicit destroy, warm-cache reuse, source-change recompile, clean shutdown.

```bash
sh tests/smoke/run.sh       # this host, dev addon
sh tests/run.sh smoke       # through the dispatcher
```

Stages (each must print its markers and exit 0): cold compile, warm reuse
(module bytes identical), source modification (`version` 1→2), recompile,
process cleanup. The runner writes `smoke-result.json` (asserted field by
field) and the shell validates the `.gdextension` mapping, produced module,
shutdown counters, and orphan processes. `GODOT_BIN`/`ZIG_BIN`/
`GZSCRIPT_SMOKE_ADDON_DIR` override the environment; no ZLS required.

What smoke proves (and does not): it answers "does a packaged build work
end to end on this OS/arch" — it is not a substitute for the full Linux
suite, editor/LSP coverage, sanitizers, or hot reload. Support tiers and
per-platform evidence live in docs/platform-support.md.
