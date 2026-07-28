# gzscript

**gzscript** is a Godot 4.7 GDExtension that enables writing Godot scripts in **Zig 0.16.0**. It automatically compiles `.zig` files to content-addressed native modules on save—no custom engine build or project `build.zig` required.

Supported platforms: macOS, Linux, and Windows (x86_64, ARM64).

## Requirements

- **Godot**: 4.7 stable
- **Zig**: 0.16.0
- **ZLS** *(optional)*: 0.16.x (for in-editor completion)

## Quick Start

1. **Build the extension**:
   ```sh
   zig build --prefix . -Doptimize=ReleaseFast
   ```
2. Copy `addons/gzscript` into your Godot project.
3. Enable **gzscript** under **Project Settings > Plugins**.
4. Restart Godot.
5. Attach a script to any Node, select **Zig** as the language, and save your `.zig` file.

## Example Script

```zig
const gd = @import("godot");

pub const Base = gd.Node2D;
const Self = @This();

base: Base,
time_passed: f64 = 0.0,
speed: f64 = 1.0,

pub const exports = gd.exports(.{
    gd.category("Movement"),
    gd.field("speed", gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    })),
});

pub const signals = .{
    .started = gd.signal(.{}),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn ready(self: *Self) !void {
    try self.base.setPosition(.{ .x = 12.0, .y = 34.0 });
    try self.base.emitSignal("started", .{});
}

pub fn process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
```

## Features

- **Automatic Async Compilation**: Background compilation keeps the Godot editor responsive during edits and saves.
- **Editor Completion**: Asynchronous ZLS integration in Godot's built-in script editor.
- **Inspector Exports**: Expose categories, groups, properties, and typed signals to the Godot Inspector.
- **Typed Node Wrappers**: Generated wrappers for `Node`, `CanvasItem`, `Control`, `Node2D`, `Sprite2D`, `Node3D`, with `gd.Object.call` as dynamic fallback.

## Testing

Run the full integration test suite:

```sh
sh tests/run.sh
```

## Current Limitations

- **Main Thread Loading**: Zig script loading must run on the main thread.
- **Instance State**: Re-compiling a script refreshes editor instances and future instances; active runtime instances retain their original module version.
- **Supported Types**: Scalars, `bool`, `[]const u8`, `Vector2`/`3`, `Color`, `Transform2D`/`3D`, `Rect2`, enums, and object references. `Array`/`Dictionary`/`Variant` values are not yet supported by the typed ABI.
