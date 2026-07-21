const gd = @import("godot");

pub const Base = gd.Node3D;
const Self = @This();

base: Base,

pub const signals = .{
    .verified = gd.signal(.{ .parent = gd.Node, .self_node = gd.Node }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn _ready(self: *Self) !void {
    const node = self.base.asNode();
    if (node.owner != self.base.owner) return error.UpcastIdentityMismatch;

    try self.base.setRotationOrder(.zyx);
    if (try self.base.getRotationOrder() != .zyx) return error.RotationOrderMismatch;
    try self.base.setRotationEditMode(.quaternion);
    if (try self.base.getRotationEditMode() != .quaternion) return error.RotationEditModeMismatch;

    try self.base.setVisible(false);
    if (try self.base.isVisible()) return error.Node3DDidNotHide;
    try self.base.setVisible(true);
    if (!(try self.base.isVisible()) or !(try self.base.isVisibleInTree())) return error.Node3DDidNotBecomeVisible;

    const parent3d = (try self.base.getParentNode3D()) orelse return error.MissingParent3D;
    const parent = (try node.getParent()) orelse return error.MissingParent;
    if (parent3d.asNode().owner != parent.owner) return error.ParentObjectMismatch;
    try self.base.emitSignal("verified", .{ parent, node });
}
