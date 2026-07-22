# Signal Support

## Understanding

- Zig scripts can declare parameterless and typed signals.
- Godot exposes those declarations through normal script signal metadata.
- Zig scripts can emit declared signals from runtime methods.
- GDScript can discover, connect to, and receive those signals.
- Signal arguments use the value types already supported by the gzscript ABI.
- Signal declarations are compile-time metadata; source parsing is out of scope.

## Assumptions

- Signal argument lists are small and can be converted on the stack.
- Signal emission is synchronous and follows Godot's normal behavior.
- The addon and Zig SDK ship together, so an ABI version bump is acceptable.
- Unsupported argument types should fail at compile time.
- Unknown signals, invalid arguments, and Godot emission failures should return errors.
- Custom Variant types and specialized editor connection UI are out of scope.

## Design

Scripts declare signals with named compile-time arguments:

```zig
pub const signals = .{
    .movement_started = gd.signal(.{}),
    .position_changed = gd.signal(.{ .position = gd.Vector2(f64) }),
};
```

The script adapter validates these declarations and creates static signal and
argument descriptors. The script descriptor exposes those arrays to the C++
bridge, which converts them to Godot `MethodInfo` and `PropertyInfo` metadata.

Scripts emit signals through their base object:

```zig
try self.base.emitSignal("position_changed", .{position});
```

The runtime converts the argument tuple to ABI values and calls an explicit
engine emission callback. The C++ bridge converts the values to Godot Variants
and emits the signal on the script owner.

## Verification

- Adapter tests verify signal names, ordering, argument names, and types.
- The example player declares a parameterless signal and a `Vector2` signal.
- The GDScript integration test verifies metadata, connections, emission count,
  and payload values.
- Formatting, native builds, Zig tests, Godot integration tests, and diff checks
  must pass.

## Decision Log

- Use compile-time descriptors instead of untyped names or source parsing.
- Preserve argument names for useful Godot editor metadata.
- Emit through an explicit engine callback instead of a dynamic method call.
- Reuse the existing ABI value conversion boundary.
- Do not add custom signal types, deferred emission, or custom editor tooling.
