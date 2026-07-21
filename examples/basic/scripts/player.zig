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

pub const signals = .{
    .zig_ready = gd.signal(.{}),
    .position_changed = gd.signal(.{ .position = gd.Vector2(f64) }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    const object = gd.Object{ .owner = self.base.owner };
    if (object.call("__gzscript_missing_method__", &.{})) |_| return error.ExpectedCallFailure else |_| {}
    try self.base.setPosition(.{ 12.0, 34.0 });
    try self.base.setRotation(0.5);
    try self.base.setScale(.{ 2.0, 3.0 });
    try self.base.moveLocalX(0.0, false);
    const position = try self.base.getPosition();
    if (position[0] != 12.0 or position[1] != 34.0) return error.PositionMismatch;
    const global_origin = try self.base.toGlobal(.{ 0.0, 0.0 });
    if (global_origin[0] != position[0] or global_origin[1] != position[1]) return error.TransformMismatch;
    try self.base.emitSignal("zig_ready", .{});
    try self.base.emitSignal("position_changed", .{position});
    gd.log.info("Zig player ready", .{});
}

pub fn _process(self: *Self, delta: f64) !void {
    self.time_passed += delta;
}
