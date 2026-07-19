const gd = @import("godot");

pub const Base = gd.Control;
const Self = @This();

base: Base,

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
