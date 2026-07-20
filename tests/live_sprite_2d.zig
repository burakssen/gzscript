const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,

pub const signals = .{
    .verified = gd.signal(.{ .parent = gd.Node, .self_node = gd.Node }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    const node2d = self.base.asNode2D();
    const canvas = self.base.asCanvasItem();
    const node = self.base.asNode();
    if (node2d.owner != self.base.owner or canvas.owner != self.base.owner or node.owner != self.base.owner) return error.UpcastIdentityMismatch;

    try node2d.setPosition(.{ .x = 21.0, .y = 34.0 });
    const position = try node2d.getPosition();
    if (position.x != 21.0 or position.y != 34.0) return error.SpritePositionMismatch;

    try self.base.setCentered(false);
    try self.base.setFlipH(true);
    try self.base.setOffset(.{ .x = 2.0, .y = 3.0 });
    if (try self.base.isCentered() or !(try self.base.isFlippedH())) return error.SpriteFlagsMismatch;

    try canvas.setVisible(false);
    if (try canvas.isVisible()) return error.SpriteDidNotHide;
    try canvas.setVisible(true);
    if (!(try canvas.isVisible()) or !(try canvas.isVisibleInTree())) return error.SpriteDidNotBecomeVisible;

    const parent = (try node.getParent()) orelse return error.MissingParent;
    if ((try node.getOwner()) != null) return error.UnexpectedSceneOwner;
    try self.base.emitSignal("verified", .{ parent, node });
}
