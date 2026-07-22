const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn process(self: *Self, delta: []const u8) !void {
    _ = self;
    _ = delta;
}
