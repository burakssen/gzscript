const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,
counter: i64 = 0,
enabled: bool = true,
speed: f64 = 2.5,
label: []const u8 = "gzscript-smoke",
point: gd.Vector(2, f64) = .{ 1.25, -9.5 },
version: i64 = 1,
calls: i64 = 0,

pub const exports = .{
    .counter = gd.property(.{}),
    .enabled = gd.property(.{}),
    .speed = gd.property(.{}),
    .label = gd.property(.{}),
    .point = gd.property(.{}),
    .version = gd.property(.{}),
    .calls = gd.property(.{}),
};

pub const signals = .{
    .smoke_ready = gd.signal(.{}),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{
        .base = .{ .owner = ctx.owner },
        .counter = 0,
        .enabled = true,
        .speed = 2.5,
        .label = "gzscript-smoke",
        .point = .{ 1.25, -9.5 },
        .version = 1,
        .calls = 0,
    };
}

pub fn ready(self: *Self) !void {
    self.counter = 42;
    try self.base.setName("SmokeNode");
    try self.base.emitSignal("smoke_ready", .{});
}

pub fn notification(self: *Self, what: i32) !void {
    if (what == 9001) {
        self.calls += 1;
    } else if (what == 9002) {
        self.counter += @as(i64, @intFromFloat(self.speed));
    }
}
