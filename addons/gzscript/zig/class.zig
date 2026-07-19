const abi = @import("abi.zig");
const runtime = @import("runtime.zig");

pub const Vector2 = abi.Vector2;

const methods = struct {
    inline fn object(self: anytype) runtime.Object {
        return .{ .owner = self.owner };
    }

    fn setPosition(self: anytype, position: Vector2) !void {
        const arguments = [_]abi.Value{.{
            .type = .vector2,
            .data = .{ .vector2 = position },
        }};
        _ = try object(self).call("set_position", &arguments);
    }

    fn getPosition(self: anytype) !Vector2 {
        const result = try object(self).call("get_position", &.{});
        if (result.type != .vector2) return error.TypeMismatch;
        return result.data.vector2;
    }
};

fn ObjectClass(comptime class_name: []const u8) type {
    return extern struct {
        owner: u64,

        pub const godot_class = class_name;
    };
}

fn Node2DClass(comptime class_name: []const u8) type {
    return extern struct {
        owner: u64,

        pub const godot_class = class_name;
        pub const set_position = methods.setPosition;
        pub const get_position = methods.getPosition;
    };
}

pub const Node = ObjectClass("Node");
pub const Control = ObjectClass("Control");
pub const Node2D = Node2DClass("Node2D");
pub const Sprite2D = Node2DClass("Sprite2D");
