const abi = @import("abi.zig");
const codec = @import("codec.zig");
const runtime = @import("runtime.zig");

fn object(value: anytype) runtime.Object {
    return .{ .owner = value.owner };
}

pub fn emitSignal(self: anytype, name: []const u8, arguments: anytype) !void {
    try object(self).emitSignal(name, arguments);
}

pub fn callVoid(self: anytype, method: []const u8, arguments: anytype) !void {
    const encoded = codec.arguments(arguments);
    _ = try object(self).call(method, &encoded);
}

pub fn call(self: anytype, comptime T: type, method: []const u8, arguments: anytype) !T {
    const encoded = codec.arguments(arguments);
    const result = try object(self).call(method, &encoded);
    return codec.fromValue(T, &result);
}

inline fn preparePtrcallArgs(arguments: anytype, arg_ptrs: anytype, engine_vecs: anytype) void {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const val = @field(arguments, field.name);
        if (comptime codec.isVector2Type(@TypeOf(val))) {
            engine_vecs[i] = .{ codec.vecX(val), codec.vecY(val) };
            arg_ptrs[i] = @ptrCast(&engine_vecs[i]);
        } else {
            arg_ptrs[i] = @ptrCast(&@field(arguments, field.name));
        }
    }
}

pub fn ptrcallVoid(self: anytype, mb: abi.MethodBind, arguments: anytype) !void {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    var arg_ptrs: [fields.len]?*const anyopaque = undefined;
    var engine_vecs: [fields.len]abi.Vector2(f32) = undefined;
    preparePtrcallArgs(arguments, &arg_ptrs, &engine_vecs);
    try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, null);
}

pub fn ptrcall(self: anytype, comptime T: type, mb: abi.MethodBind, arguments: anytype) !T {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    var arg_ptrs: [fields.len]?*const anyopaque = undefined;
    var engine_vecs: [fields.len]abi.Vector2(f32) = undefined;
    preparePtrcallArgs(arguments, &arg_ptrs, &engine_vecs);

    if (comptime codec.isVector2Type(T)) {
        var raw_res: abi.Vector2(f32) = undefined;
        try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, @ptrCast(&raw_res));
        return codec.makeVec2(T, raw_res[0], raw_res[1]);
    } else {
        var result: T = undefined;
        try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, @ptrCast(&result));
        return result;
    }
}
