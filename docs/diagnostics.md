# gzscript diagnostics architecture

> `GzDiagnosticStore` is the single source of truth for source-code
> diagnostics. Producers submit complete, generation-tagged diagnostic sets;
> consumers read immutable snapshots. The store knows nothing about ZLS, the
> Zig compiler, or Godot's editor UI.

## Model

- `GzDiagnosticSeverity`: `Error`, `Warning`, `Information`, `Hint`
  (protocol-neutral; adapters translate to/from LSP and Godot).
- `GzSourcePosition`: **zero-based** `{line, column}` (LSP-aligned).
- `GzSourceRange`: **end-exclusive** `[start, end)`. Point diagnostics use
  `start == end` (no fake ranges, no optionals).
- `GzDiagnosticSource`: `Zls`, `ZigCompiler`, `GzScript`, plus a stable
  human-readable origin name (`zls`, `zig`, `gzscript`).
- `GzDiagnostic`: document key, range, severity, origin, message, optional
  code. Structured data only — never preformatted UI text.
- Validity: a snapshot with any `Error` is invalid; warnings and below are
  valid. Deterministic ordering: start line, start column, severity rank,
  source, message.

## Document identity

Store keys are canonical absolute filesystem paths produced by
`gz_normalize_document_path()` (engine-independent): duplicate-slash
collapse, `./`/`../` resolution, `file://` URI decoding, Windows drive
casing/backslashes, scheme preservation (`res://` passes through untouched).
No lowercasing anywhere. `res://` → absolute mapping needs
`ProjectSettings` and lives in the Godot adapter, which normalizes
afterwards.

## Generations

Documents are explicitly registered (`open_document`, generation starts at
1); every content change advances the generation (content revision, not a
filesystem-operation counter). `replace()` applies only when
`update.generation == current`:

- older → `Stale` (rejected, counted)
- unknown document → `UnknownDocument` (late results can never resurrect
  removed documents)
- newer than current → `FutureGeneration` (producers must not move state
  forward; rejected, counted)
- equal → applied; identical batches are accepted without dirty-marking.

Same-generation replacements from one source are valid (latest wins);
different sources coexist at the same generation.

## Storage and snapshots

Per document: generation, closed flag, and per-source diagnostic vectors.
Replacement is atomic (never incremental add/remove while parsing).
`snapshot(path)` merges all sources deterministically;
`snapshot_source(path, source)` views one producer (useful for asserting
"ZLS cleared, compiler diagnostics remain"). Snapshots are value copies —
consumers must never retain references into store state.

Clearing: `clear_source` (one producer), `clear_document` (all producers,
generation tracking kept), `clear_all_from_source` (e.g. ZLS restart),
`remove_document` (full erase). Clearing non-empty state marks the document
changed. Closing a document (`close_document`, e.g. editor tab closed) keeps
diagnostics and still accepts updates; deletion forgets everything.

## Threading contract (hard invariant)

- Producer threads may update the store; the Godot main thread may query it
  and drain `take_changed_documents()` (deduplicated, insertion order).
- The store never calls Godot/engine APIs and never invokes callbacks while
  holding its lock. Updates are short lock/copy/unlock cycles; sorting and
  formatting happen outside.
- `GzLanguage::_validate()` consumes snapshots on the main thread and never
  triggers compilation — the editor sees the most recently known state.

## Producer contract

> Never mutate the store incrementally while parsing. Construct a complete
> diagnostic batch and submit it atomically via `replace()`.

Parse completely → normalize → submit. Ranges with `end < start` are
collapsed to a point and counted (`ranges_normalized`); identical batches
are no-ops for change notification.

## Godot mapping

`_validate()` returns `valid` plus `errors`/`warnings` arrays in the exact
shapes upstream `ScriptLanguageExtension::validate()` expects (verified
against `core/object/script_language_extension.h`):

- errors: `{path, line, column, message}` — one-based, point semantics
  (`start_line = end_line = line` upstream).
- warnings: `{start_line, end_line, string_code, message}` — one-based.

Positions are clamped to int32 at the boundary. With no producers (current
phase), untracked documents yield empty snapshots and `valid = true`.

## Ownership and lifetime

`register_types` owns the store (`shared_ptr`), creates it before the
managers, hands a copy to `GzLanguage`, and destroys it after the managers
are shut down and deleted — so it outlives every producer. No raw store
pointers in long-running jobs; async producers must be joined before
teardown (Phase 1 shutdown order).

## Observability

`stats()` (applied/stale/future/unknown/noop/normalized counters),
`debug_dump()` (per-document listing), and `GZ_DIAGNOSTIC_TRACE` traces.
Debug counters print in the shutdown summary path like the Phase 1
lifecycle counters.

## Tests

Engine-independent C++ tests under `tests/diagnostics/` (built with
`zig c++`, no Godot): model, store, generations, paths, snapshots/queue,
concurrency (also runnable under ThreadSanitizer via `GZSCRIPT_TSAN=1` on
Linux). Run with `sh tests/diagnostics/run.sh` or
`sh tests/run.sh diagnostics`.
