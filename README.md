# gzscript

gzscript is a Godot 4.7 GDExtension that makes Zig 0.16 scripts attachable to Godot objects. It compiles each `.zig` script to a content-addressed native module automatically, without a project `build.zig` or a custom Godot build.

The current MVP targets macOS, Linux, and Windows on x86_64 and ARM64.

`build.zig.zon` pins godot-cpp commit `ba0edfed90512ec64aba51d4295a3e7e30112f86`, whose extension API reports Godot 4.7 stable. Zig fetches it automatically.

## Requirements

- Godot 4.7 stable
- Zig 0.16.0 installed locally
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

gzscript resolves the compiler from **Project Settings > Gzscript > Compiler > Zig Path**, then `GZSCRIPT_ZIG_PATH`, then the standard zvm path at `~/.zvm/bin/zig`, and finally `zig` on `PATH`. Set **Zig Path** to an absolute executable path when using another version manager or when Godot is launched from the macOS GUI.

The addon compiles scripts on resource load and save. Its editor plugin also recompiles loaded Zig scripts after filesystem changes and immediately before Run. A failed build blocks Run and leaves the `.zig` resource attached.

Generated adapters and libraries are stored below `.godot/gzscript` and can be deleted safely.

Runtime modules default to Zig's `Debug` optimization mode. Change **Project
Settings > Gzscript > Compiler > Optimization** to `ReleaseSafe`,
`ReleaseFast`, or `ReleaseSmall` when testing exported-project performance. The
optimization mode is part of the module cache identity.

The cache identity includes the script path and source, every `.zig` file below
the script's directory, the complete bundled Zig SDK and generated bindings,
the ABI and adapter versions, the selected Zig executable and reported version,
the platform, architecture, and optimization mode. This conservative policy may
recompile when an unrelated Zig file in the same directory changes, but it does
not reuse a module after a relative import changes. In-memory source must be
saved before compilation so the cache identity cannot differ from the file Zig
actually compiles.

## Script API

```zig
const gd = @import("godot");

pub const Base = gd.Node2D;
const Self = @This();

base: Base,
time_passed: f64 = 0.0,
amplitude: f64 = 10.0,
speed: f64 = 1.0,

pub const exports = .{
    .amplitude = gd.property(.{
        .category = "Movement",
        .range = .{ .min = 0.0, .max = 100.0, .step = 0.1 },
    }),
    .speed = gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    try self.base.setPosition(.{ .x = 12.0, .y = 34.0 });
    gd.log.info("ready", .{});
}

pub fn _process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
```

Only fields listed in `exports` are visible to Godot. Exported fields must have defaults. The MVP supports `bool`, integer types, `f32`, `f64`, `[]const u8`, and `gd.Vector2(T)` descriptor types. Script templates are generated for the selected Godot base class.

Signals use named, typed arguments and are emitted through the base object:

```zig
pub const signals = .{
    .started = gd.signal(.{}),
    .position_changed = gd.signal(.{ .position = gd.Vector2(f64) }),
};

try self.base.emitSignal("started", .{});
try self.base.emitSignal("position_changed", .{position});
```

`gd.Node2D` and `gd.Sprite2D` provide typed wrappers for the Godot 4.7 position, rotation, skew, scale, translation, look-at, and local/global point methods supported by ABI v2. Use `gd.Object.call` as the fallback for Godot methods that do not have typed wrappers yet. Dynamic calls report missing methods and invalid arguments as Zig errors. Export additions and removals refresh the selected node's Inspector after a successful save.

The typed wrappers are generated from the pinned Godot API metadata and checked into the addon:

```sh
zig build update-bindings
zig build check-bindings
```

`tools/bindings_profile.json` contains the reviewed root classes. The host Zig generator reads the pinned `extension_api.json`, emits every instance method supported by the current scalar, object, string-input, and `Vector2` type matrix, and derives required enums and dependency-only class wrappers from those signatures. Generated classes live in compact modules under `addons/gzscript/zig/generated_classes`; mutually dependent types are grouped into deterministic cycle modules. `class.zig` remains the stable compatibility facade, and CI validates the complete generated manifest and file contents.

## Tests

```sh
sh tests/run.sh
```

This runs Zig reflection tests, headless lifecycle/property and save integration tests, invalid-source handling, and editor language/export refresh checks.

Benchmarks are intentionally separate from the correctness gate because shared
CI runners do not provide stable timing. After building and importing the
project, run them manually with:

```sh
GZSCRIPT_ZIG_PATH="$(command -v zig)" \
  godot --headless --path . --script tests/benchmark_runner.gd
```

## Reload contract

A successful reload publishes the new module for future instances and refreshes
editor metadata. Existing instances keep the exact module and Zig-owned state
with which they were created. A failed reload does not replace that module, so
existing instances remain safe, but the script is marked invalid and cannot
create new instances until a later successful reload. `keep_state` does not
currently migrate private or exported state between module versions.

## MVP limitations

- Mobile and Web exports are not implemented.
- Active instances are not migrated after recompilation; see the reload contract above.
- Script callbacks currently cover `_ready`, `_process`, and `_physics_process`.
- Generated typed methods are currently limited to the ABI v2 scalar, object ID, string-input, and `Vector2` type matrix.
- `Vector3`, transforms, colors, rectangles, arrays, dictionaries, packed arrays, `Callable`, and general `Variant` values are not yet supported by the typed ABI.
