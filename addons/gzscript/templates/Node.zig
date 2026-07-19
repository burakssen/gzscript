const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    _ = self;
}
