const std = @import("std");
const gd = @import("godot");

const TestScript = struct {
    pub const Base = gd.Node2D;
    const Self = @This();

    base: Base,
    internal: f64 = 0,
    amplitude: f64 = 10,

    pub const exports = .{
        .amplitude = gd.property(.{ .category = "Movement", .range = .{ .min = 0, .max = 100, .step = 0.1 } }),
    };

    pub const signals = .{
        .started = gd.signal(.{}),
        .position_changed = gd.signal(.{ .position = gd.Vector2 }),
    };

    pub fn init(ctx: gd.InitContext) !Self {
        return .{ .base = .{ .owner = ctx.owner } };
    }

    pub fn _ready(_: *Self) !void {}
};

test "adapter reflects explicit exports only" {
    const descriptor = gd.ScriptAdapter(TestScript).descriptor;
    try std.testing.expectEqual(@as(u32, 1), descriptor.property_count);
    try std.testing.expectEqualStrings("amplitude", descriptor.properties.?[0].name.slice());
    try std.testing.expectEqualStrings("Movement", descriptor.properties.?[0].category.slice());
    try std.testing.expectEqual(@as(f64, 10), descriptor.properties.?[0].default_value.data.floating);
    try std.testing.expectEqualStrings("Node2D", descriptor.base_class.slice());
}

test "adapter reflects signal declarations" {
    const descriptor = gd.ScriptAdapter(TestScript).descriptor;
    try std.testing.expectEqual(@as(u32, 2), descriptor.signal_count);
    try std.testing.expectEqualStrings("started", descriptor.signals.?[0].name.slice());
    try std.testing.expectEqual(@as(u32, 0), descriptor.signals.?[0].argument_count);
    try std.testing.expectEqualStrings("position_changed", descriptor.signals.?[1].name.slice());
    try std.testing.expectEqual(@as(u32, 1), descriptor.signals.?[1].argument_count);
    try std.testing.expectEqualStrings("position", descriptor.signals.?[1].arguments.?[0].name.slice());
    try std.testing.expectEqual(gd.abi.ValueType.vector2, descriptor.signals.?[1].arguments.?[0].type);
}

test "2D wrappers expose typed position methods" {
    try std.testing.expect(@hasDecl(gd.Node2D, "set_position"));
    try std.testing.expect(@hasDecl(gd.Node2D, "get_position"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "set_position"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "get_position"));
}

test "class factories preserve identity and ABI layout" {
    comptime {
        if (gd.Node == gd.Control) @compileError("Node and Control must be distinct types");
        if (gd.Node2D == gd.Sprite2D) @compileError("Node2D and Sprite2D must be distinct types");
    }

    try std.testing.expectEqualStrings("Node", gd.Node.godot_class);
    try std.testing.expectEqualStrings("Control", gd.Control.godot_class);
    try std.testing.expectEqualStrings("Node2D", gd.Node2D.godot_class);
    try std.testing.expectEqualStrings("Sprite2D", gd.Sprite2D.godot_class);

    inline for (.{ gd.Node, gd.Control, gd.Node2D, gd.Sprite2D }) |Class| {
        try std.testing.expectEqual(@sizeOf(u64), @sizeOf(Class));
        try std.testing.expectEqual(@alignOf(u64), @alignOf(Class));
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(Class, "owner"));
        try std.testing.expect(@hasDecl(Class, "emit_signal"));
    }

    try std.testing.expect(!@hasDecl(gd.Node, "set_position"));
    try std.testing.expect(!@hasDecl(gd.Control, "set_position"));
}
