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
    try self.base.set_position(.{ .x = 12.0, .y = 34.0 });
    const position = try self.base.get_position();
    if (position.x != 12.0 or position.y != 34.0) return error.PositionMismatch;
    gd.log.info("Zig player ready", .{});
}

pub fn _process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
