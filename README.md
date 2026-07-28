# gzscript

gzscript is a Godot 4.7 GDExtension that makes Zig 0.16 scripts attachable to Godot objects. It compiles each `.zig` script to a content-addressed native module automatically, without a project `build.zig` or a custom Godot build.

The current MVP targets macOS, Linux, and Windows on x86_64 and ARM64.

`build.zig.zon` pins godot-cpp commit `ba0edfed90512ec64aba51d4295a3e7e30112f86`, whose extension API reports Godot 4.7 stable. Zig fetches it automatically.

## Requirements

- Godot 4.7 stable, single-precision build
- Zig 0.16.0 installed locally
- ZLS 0.16.x (optional, for built-in editor completion)
- macOS, Linux, or Windows on x86_64 or ARM64

## Build

Build the extension for the current desktop platform. Zig fetches godot-cpp,
restores the pinned Godot 4.7 generated C++ bindings, and builds both godot-cpp
and gzscript without Python, SCons, or CMake:

```sh
zig build --prefix . -Doptimize=Debug
zig build --prefix . -Doptimize=ReleaseFast
```

Use Zig's standard `-Dtarget` option for another supported target, such as
`-Dtarget=x86_64-linux-gnu`. `--prefix .` writes the resulting extension to
`addons/gzscript/bin`; without it, Zig installs below `zig-out`. The Zig
SDK in `addons/gzscript/zig` is the canonical source used by both development
builds and release packages. `Debug` produces Godot's debug library;
`ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall` produce its release library.

The `gzscript-desktop` GitHub Actions artifact is an installable package with
the complete `addons/gzscript` directory. It includes debug and release builds
for macOS, Linux, and Windows on x86_64 and ARM64.

## Use

1. Build the extension locally or download a prebuilt release artifact.
2. Copy `addons/gzscript` into a Godot 4.7 project.
3. Enable **gzscript** under **Project > Project Settings > Plugins**.
4. Restart the editor.
5. Select a node and use **Attach Script**.
6. Choose **Zig**, create a `.zig` file, and save it.

## Editor completion

gzscript uses ZLS asynchronously for completion in Godot's built-in script
editor. Install a ZLS 0.16.x release matching Zig 0.16, then restart Godot.
gzscript resolves ZLS from **Project Settings > gzscript > language_server >
zls_path**, `GZSCRIPT_ZLS_PATH`, the standard zvm path at `~/.zvm/bin/zls`, or
`PATH`, in that order. The editor continues to work without ZLS, but semantic
completion is unavailable.

Completion never waits for a ZLS response on the editor thread: requests are
debounced, only the latest query is sent, and response processing is bounded per
frame before the popup is refreshed. Snippets,
hover, diagnostics, formatting, semantic tokens, rename, and references are not
integrated yet. Save and Run diagnostics continue to come from the Zig compiler.

gzscript resolves the compiler from **Project Settings > Gzscript > Compiler > Zig Path**, then `GZSCRIPT_ZIG_PATH`, then the standard zvm path at `~/.zvm/bin/zig`, and finally `zig` on `PATH`. Set **Zig Path** to an absolute executable path when using another version manager or when Godot is launched from the macOS GUI.

The addon compiles scripts synchronously on runtime resource loads. Editor loads,
saves, and filesystem changes queue a serialized asynchronous Zig process so
the editor remains responsive. Repeated saves are coalesced and stale results
are discarded. Run waits for pending work and performs a final synchronous
check; a failed build blocks Run and leaves the `.zig` resource attached.

Source saves are written and synced to a temporary file before atomically
replacing the destination. The old path remains readable until the complete new
source is ready, and successful saves sync the containing directory on POSIX.

Generated adapters and libraries are stored below `.godot/gzscript` and can be deleted safely.

Runtime modules default to Zig's `Debug` optimization mode. Change **Project
Settings > Gzscript > Compiler > Optimization** to `ReleaseSafe`,
`ReleaseFast`, or `ReleaseSmall` when measuring runtime performance. The
optimization mode is part of the module cache identity.

The cache identity includes the script path and source, transitive literal
relative `@import` and `@embedFile` dependencies, the complete bundled Zig SDK
and generated bindings, the ABI and adapter versions, the selected Zig
executable and reported version, the platform, architecture, and optimization
mode. Unsupported import expressions conservatively fall back to directory
fingerprinting. Unrelated project files do not invalidate normal scripts, while
relative imports and embedded inputs remain tracked. In-memory source must be
saved before compilation so the cache identity cannot differ from the file Zig
actually compiles. Successful builds are re-fingerprinted before publication,
and cache stamps authenticate both the source identity and compiled module
bytes. A per-key operating-system file lock coordinates separate Godot
processes; the lock covers the final cache check, compilation, module
validation, and atomic module/stamp publication.

Compiler processes time out after two minutes. gzscript retains up to 64 KiB of
compiler output and marks truncated diagnostics while continuing to drain the
process pipes. Timeout and shutdown cleanup terminate the compiler process group
and captured descendants before releasing its cache key.

## Script API

```zig
const gd = @import("godot");

pub const Base = gd.Node2D;
const Self = @This();

base: Base,
time_passed: f64 = 0.0,
amplitude: f64 = 10.0,
speed: f64 = 1.0,

pub const exports = gd.exports(.{
    gd.category("Movement"),
    gd.group("Oscillation", ""),
    gd.field("amplitude", gd.property(.{
        .range = .{ .min = 0.0, .max = 100.0, .step = 0.1 },
    })),
    gd.subgroup("Timing", ""),
    gd.field("speed", gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    })),
});

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn ready(self: *Self) !void {
    try self.base.setPosition(.{ .x = 12.0, .y = 34.0 });
    gd.log.info("ready", .{});
}

pub fn process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
```

Only fields listed with `gd.field` are visible to Godot. Exported fields must have declaration defaults. `gd.category`, `gd.group`, and `gd.subgroup` organize the following fields in declaration order. Group and subgroup prefixes follow Godot's rules: matching prefixes are removed from displayed property names. Use `gd.endGroup()` before the next field to return to the ungrouped Inspector section. Groups cannot be nested, and a subgroup requires an active group; invalid layouts fail at compile time.

The previous named form remains supported for source compatibility:

```zig
pub const exports = .{
    .amplitude = gd.property(.{ .category = "Movement" }),
    .speed = gd.property(.{}),
};
```

New scripts should prefer the ordered form because it makes category and group boundaries explicit. Property options reject unknown names, invalid ranges, and conflicting range hints. The MVP supports `bool`, `i8` through `i64`, `u8` through `u32`, `f32`, `f64`, `[]const u8`, `gd.Vector(2, T)`, `gd.Vector(3, T)`, `gd.Color`, `gd.Transform2D`, `gd.Transform3D`, `gd.Rect2`, enums, and Godot object wrappers. Script templates are generated for the selected Godot base class.

Signals use named, typed arguments and are emitted through the base object:

```zig
pub const signals = .{
    .started = gd.signal(.{}),
    .position_changed = gd.signal(.{ .position = gd.Vector(2, f64) }),
};

try self.base.emitSignal("started", .{});
try self.base.emitSignal("position_changed", .{position});
```

Generated wrappers cover the reviewed `Node`, `CanvasItem`, `Control`, `Node2D`, `Sprite2D`, and `Node3D` APIs supported by ABI v5, including transforms, drawing, colors, rectangles, visibility, hierarchy, and object-returning methods. Object exports retain `RefCounted` values and reject incompatible Godot classes. Use `gd.Object.call` as the fallback for methods outside that generated surface. Dynamic calls report missing methods and invalid arguments as Zig errors. Export additions, removals, categories, and groups refresh the selected node's Inspector after a successful save.

The typed wrappers are generated from the pinned Godot API metadata and checked into the addon:

```sh
zig build update-bindings
zig build check-bindings
```

`tools/bindings_profile.json` contains the reviewed root classes. The host Zig generator reads the pinned `extension_api.json`, emits every instance method supported by the current ABI type matrix, and derives required enums and dependency-only class wrappers from those signatures. Generated classes live in compact modules under `addons/gzscript/zig/generated_classes`; mutually dependent types are grouped into deterministic cycle modules. `class.zig` remains the stable compatibility facade, and CI validates the complete generated manifest and file contents.

## Tests

```sh
sh tests/run.sh
```

This runs Zig reflection tests, headless lifecycle/property and save integration
tests, cache substitution and mid-build dependency race checks, compiler process
limits, invalid-source handling, and editor language/export refresh checks.
When ZLS is installed, the editor test also verifies semantic completion.

Benchmarks are intentionally separate from the correctness gate because shared
CI runners do not provide stable timing. After building and importing the
project, run them manually with:

```sh
GZSCRIPT_ZIG_PATH="$(command -v zig)" \
  godot --headless --path . --script tests/benchmark_runner.gd
```

## Reload contract

A successful reload publishes the new module for future instances and refreshes
editor metadata. Runtime instances keep the exact module and Zig-owned state
with which they were created. Editor instances are recreated against the new
module so Inspector exports update immediately; name/type-compatible exports
are preserved, while private Zig state is reset. A failed reload does not
replace the accepted module or active instances. `keep_state` does not migrate
runtime state between module versions. While an asynchronous save is pending,
the last accepted module remains active.

## MVP limitations

- Packaged project exports are not implemented yet; development currently requires loose source files and a local Zig compiler.
- Threaded `ResourceLoader` requests for Zig scripts are rejected; initial loads must run on the main thread.
- Active instances are not migrated after recompilation; see the reload contract above.
- Only the listed Godot virtual callbacks are callable; arbitrary public Zig methods, static methods, RPC metadata, tool scripts, inheritance, and global script classes are not implemented yet.
- Editor validation, hover, asynchronous symbol lookup, debugger stacks, and profiling integration are not implemented yet. Completion is provided by an optional matching ZLS installation. Compilation diagnostics are reported when a resource is loaded, saved, or Run is requested.
- Strings returned by raw `gd.Object.call` borrow engine storage until the next dynamic call on the same thread. Returned object wrappers are unowned IDs and are safe only while Godot or another owner retains the object.
- Zig callbacks map `ready`, `enterTree`, `exitTree`, `process`, `physicsProcess`, `input`, `unhandledInput`, `shortcutInput`, `unhandledKeyInput`, `guiInput`, and `draw` to their Godot virtual methods. An optional `notification` method receives other Godot notifications by number.
- Generated typed methods are limited to the ABI v5 scalar, typed object ID, string-input, vector, color, transform, rectangle, and enum type matrix.
- Arrays, dictionaries, packed arrays, `Callable`, and general `Variant` values are not yet supported by the typed ABI.
