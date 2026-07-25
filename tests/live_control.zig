const gd = @import("godot");

pub const Base = gd.Control;
const Self = @This();

base: Base,

pub const signals = .{
    .verified = gd.signal(.{ .parent = gd.Node, .self_node = gd.Node }),
    .color_verified = gd.signal(.{ .color = gd.Color }),
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

    const expected_color = gd.Color{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1.0 };
    try self.base.addThemeColorOverride("font_color", expected_color);
    const actual_color = try self.base.getThemeColor("font_color", "");
    if (actual_color.r != expected_color.r or actual_color.g != expected_color.g or actual_color.b != expected_color.b or actual_color.a != expected_color.a) return error.ThemeColorMismatch;

    try canvas.setVisible(false);
    if (try canvas.isVisible()) return error.ControlDidNotHide;
    try canvas.setVisible(true);
    if (!(try canvas.isVisible()) or !(try canvas.isVisibleInTree())) return error.ControlDidNotBecomeVisible;

    const parent_node = (try node.getParent()) orelse return error.MissingParent;
    const parent_control = (try self.base.getParentControl()) orelse return error.MissingParentControl;
    if (parent_node.owner != parent_control.asNode().owner) return error.ParentObjectMismatch;
    if ((try node.getOwner()) != null) return error.UnexpectedSceneOwner;

    try self.base.emitSignal("verified", .{ parent_node, node });
    try self.base.emitSignal("color_verified", .{expected_color});
}
