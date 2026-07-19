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
