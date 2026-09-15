const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,
pings: i64 = 0,

pub const exports = .{ .pings = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn notification(self: *Self, what: i32) !void {
    if (what == 9001) self.pings += 1;
}
