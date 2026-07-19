const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
time_passed: f64 = 0.0,
amplitude: f64 = 10.0,
speed: f64 = 1.0,

pub const exports = .{
    .amplitude = gd.property(.{ .category = "Movement", .range = .{ .min = 0.0, .max = 100.0, .step = 0.1 } }),
    .speed = gd.property(.{ .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 } }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    _ = self;
}
