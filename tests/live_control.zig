const gd = @import("godot");

pub const Base = gd.Control;
const Self = @This();

base: Base,

pub const signals = .{
    .verified = gd.signal(.{ .parent = gd.Node, .self_node = gd.Node }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn ready(self: *Self) !void {
    const canvas = self.base.asCanvasItem();
    const node = self.base.asNode();
    if (canvas.owner != self.base.owner or node.owner != self.base.owner) return error.UpcastIdentityMismatch;

    try self.base.setPosition(.{ 11.0, 13.0 }, false);
    const position = try self.base.getPosition();
    if (position[0] != 11.0 or position[1] != 13.0) return error.ControlPositionMismatch;

    try self.base.setLayoutDirection(.ltr);
    if (try self.base.getLayoutDirection() != .ltr) return error.LayoutDirectionMismatch;

    try canvas.setVisible(false);
    if (try canvas.isVisible()) return error.ControlDidNotHide;
    try canvas.setVisible(true);
    if (!(try canvas.isVisible()) or !(try canvas.isVisibleInTree())) return error.ControlDidNotBecomeVisible;

    const parent_node = (try node.getParent()) orelse return error.MissingParent;
    const parent_control = (try self.base.getParentControl()) orelse return error.MissingParentControl;
    if (parent_node.owner != parent_control.asNode().owner) return error.ParentObjectMismatch;
    if ((try node.getOwner()) != null) return error.UnexpectedSceneOwner;

    try self.base.emitSignal("verified", .{ parent_node, node });
}
