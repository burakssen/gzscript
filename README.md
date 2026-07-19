# gzscript

gzscript is a Godot 4.7 GDExtension that makes Zig 0.16 scripts attachable to Godot objects. It compiles each `.zig` script to a content-addressed native module automatically, without a project `build.zig` or a custom Godot build.

The current MVP targets macOS ARM64.

The `godot-cpp` submodule is pinned to commit `ba0edfed90512ec64aba51d4295a3e7e30112f86`, whose extension API reports Godot 4.7 stable.

## Requirements

- Godot 4.7 stable
- Zig 0.16.0 installed locally
- macOS ARM64
- `uv` for the documented build command

## Build

Initialize the dependency after cloning:

```sh
git submodule update --init
```

Build the extension:

```sh
uvx --from scons scons platform=macos target=template_debug arch=arm64 -j8
```

The resulting extension is written to `addons/gzscript/bin`. The Zig SDK in `addons/gzscript/zig` is the canonical source used by both development builds and release packages. Prebuilt frameworks are distributed as release artifacts rather than committed to the source repository.

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
    _ = self;
    gd.log.info("ready", .{});
}

pub fn _process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
```

Only fields listed in `exports` are visible to Godot. Exported fields must have defaults. The MVP supports `bool`, integer types, `f32`, `f64`, `[]const u8`, and `gd.Vector2` descriptor types. The bundled templates currently cover `Node`, `Node2D`, `Sprite2D`, and `Control`.

## Tests

```sh
sh tests/run.sh
```

This runs Zig reflection tests, a headless lifecycle/property integration test, invalid-source handling, and a headless editor startup check.

## MVP limitations

- macOS ARM64 only.
- Active instances are not migrated after recompilation.
- Export presets and cross-compilation are not implemented yet.
- Script callbacks currently cover `_ready`, `_process`, and `_physics_process`.
- Godot API wrappers currently expose object ownership, logging, and dynamic method calls rather than generated typed methods for every engine class.
