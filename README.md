# gzscript

gzscript is a Godot 4.7 GDExtension that makes Zig 0.16 scripts attachable to Godot objects. It compiles each `.zig` script to a content-addressed native module automatically, without a project `build.zig` or a custom Godot build.

The current MVP targets macOS, Linux, and Windows on x86_64 and ARM64.

The `godot-cpp` submodule is pinned to commit `ba0edfed90512ec64aba51d4295a3e7e30112f86`, whose extension API reports Godot 4.7 stable.

## Requirements

- Godot 4.7 stable
- Zig 0.16.0 installed locally
- macOS, Linux, or Windows on x86_64 or ARM64
- `uv` for the documented build command

## Build

Initialize the dependency after cloning:

```sh
git submodule update --init
```

Build the extension for the current desktop platform. Supported SCons platform
and architecture combinations are `macos`/`x86_64`, `macos`/`arm64`,
`linux`/`x86_64`, `linux`/`arm64`, `windows`/`x86_64`, and
`windows`/`arm64`:

```sh
uvx --from scons scons platform=macos target=template_debug arch=arm64 -j8
uvx --from scons scons platform=macos target=template_release arch=arm64 -j8
```

Replace the platform and architecture values when building natively on Linux or
Windows. The resulting extension is written to `addons/gzscript/bin`. The Zig
SDK in `addons/gzscript/zig` is the canonical source used by both development
builds and release packages.

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

Only fields listed in `exports` are visible to Godot. Exported fields must have defaults. The MVP supports `bool`, integer types, `f32`, `f64`, `[]const u8`, and `gd.Vector2` descriptor types. The bundled templates currently cover `Node`, `Node2D`, `Sprite2D`, and `Control`.

Signals use named, typed arguments and are emitted through the base object:

```zig
pub const signals = .{
    .started = gd.signal(.{}),
    .position_changed = gd.signal(.{ .position = gd.Vector2 }),
};

try self.base.emitSignal("started", .{});
try self.base.emitSignal("position_changed", .{position});
```

`gd.Node2D` and `gd.Sprite2D` provide typed wrappers for the Godot 4.7 position, rotation, skew, scale, translation, look-at, and local/global point methods supported by ABI v2. Use `gd.Object.call` as the fallback for Godot methods that do not have typed wrappers yet. Dynamic calls report missing methods and invalid arguments as Zig errors. Export additions and removals refresh the selected node's Inspector after a successful save.

The typed wrappers are generated from the pinned Godot API metadata and checked into the addon:

```sh
python3 tools/generate_bindings.py
python3 tools/generate_bindings.py --check
```

`tools/bindings_profile.json` is the reviewed API allowlist. SCons regenerates the wrappers when the profile, generator, or Godot API metadata changes, and CI rejects stale generated output.

## Tests

```sh
sh tests/run.sh
```

This runs Zig reflection tests, headless lifecycle/property and save integration tests, invalid-source handling, and editor language/export refresh checks.

## MVP limitations

- Mobile and Web exports are not implemented.
- Active instances are not migrated after recompilation.
- Script callbacks currently cover `_ready`, `_process`, and `_physics_process`.
- Generated typed methods are currently limited to the ABI v2 scalar, object ID, string-input, and `Vector2` codecs selected in `tools/bindings_profile.json`.
- `Vector3`, transforms, colors, rectangles, arrays, dictionaries, packed arrays, `Callable`, and general `Variant` values are not yet supported by the typed ABI.
