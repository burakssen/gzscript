const gd = @import("godot");
const std = @import("std");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
some_enum: i64 = 0,
some_file: []const u8 = "",
some_text: []const u8 = "",
held_texture: ?gd.Texture2D = null,
enter_tree_notification_received: bool = false,

pub const exports = gd.exports(.{
    gd.category("Metadata"),
    gd.group("Values", "some_"),
    gd.field("some_enum", gd.property(.{ .hint = .@"enum", .hint_string = "First,Second,Third" })),
    gd.field("some_file", gd.property(.{ .hint = .file, .hint_string = "*.zig" })),
    gd.subgroup("Text", "some_"),
    gd.field("some_text", gd.property(.{ .hint = .multiline_text })),
    gd.endGroup(),
    gd.field("held_texture", gd.property(.{})),
});

pub const signals = .{
    .verified = gd.signal(.{ .parent = gd.Node, .self_node = gd.Node }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{
        .base = .{ .owner = ctx.owner },
        .some_enum = 0,
        .some_file = "",
        .some_text = "",
        .held_texture = null,
        .enter_tree_notification_received = false,
    };
}

pub fn notification(self: *Self, what: i32) !void {
    if (what == 10) { // NOTIFICATION_ENTER_TREE = 10
        self.enter_tree_notification_received = true;
    } else if (what == 9001) {
        self.held_texture = null;
    } else if (what == 9002) {
        self.held_texture = try self.base.getTexture();
    } else if (what == 9003) {
        self.held_texture = .{ .owner = self.base.owner };
    }
}

pub fn ready(self: *Self) !void {
    if (!self.enter_tree_notification_received) return error.NotificationNotReceived;

    const node2d = self.base.asNode2D();
    const canvas = self.base.asCanvasItem();
    const node = self.base.asNode();
    if (node2d.owner != self.base.owner or canvas.owner != self.base.owner or node.owner != self.base.owner) return error.UpcastIdentityMismatch;

    try node2d.setPosition(.{ 21.0, 34.0 });
    const position = try node2d.getPosition();
    if (position[0] != 21.0 or position[1] != 34.0) return error.SpritePositionMismatch;

    try canvas.setModulate(.{ .r = 0.5, .g = 0.25, .b = 0.75, .a = 1.0 });
    const modulate = try canvas.getModulate();
    if (modulate.r != 0.5 or modulate.g != 0.25 or modulate.b != 0.75 or modulate.a != 1.0) return error.ColorMismatch;

    try self.base.setCentered(false);
    try self.base.setFlipH(true);
    try self.base.setOffset(.{ 2.0, 3.0 });

    if (try self.base.isCentered() or !(try self.base.isFlippedH())) return error.SpriteFlagsMismatch;

    try canvas.setVisible(false);
    if (try canvas.isVisible()) return error.SpriteDidNotHide;
    try canvas.setVisible(true);
    if (!(try canvas.isVisible()) or !(try canvas.isVisibleInTree())) return error.SpriteDidNotBecomeVisible;

    const parent = (try node.getParent()) orelse return error.MissingParent;
    if ((try node.getOwner()) != null) return error.UnexpectedSceneOwner;

    try self.base.emitSignal("verified", .{ parent, node });
}

pub fn enterTree(self: *Self) !void {
    std.log.info("Sprite2D enter tree via std.log", .{});
    _ = self;
}

pub fn draw(self: *Self) !void {
    std.log.info("Sprite2D draw via std.log", .{});
    _ = self;
}
